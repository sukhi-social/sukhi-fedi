# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.RateLimitPlug do
  @moduledoc """
  Per-peer rate limiter backed by Hammer (ETS buckets, node-local).

  Intended for externally-reachable endpoints — the inbox, WebFinger,
  and Mastodon-compat API. Node-local is fine because abusive remote
  servers will hit every node roughly equally if we're scaled
  horizontally.

  Options:
    * `:limit`     — allowed hits per window (default 100)
    * `:scale_ms`  — window length (default 60_000 ms)
    * `:bucket`    — label prefix, lets different routes share limits
                     or isolate them (default "rl")
    * `:skip_prefixes` — request-path prefixes that are not counted at
                     all. For files served as-is from disk (the SPA
                     build, custom emoji): one page of them is easily
                     hundreds of requests, and counting them starves
                     the API calls that share the bucket (default `[]`)
    * `:skip_if`   — `fun(conn) :: boolean`, for requests that cannot be
                     named by a prefix. The router passes
                     `SpaRoutes.page_request?/1`: the SPA shell must
                     reach a browser even while its IP is over the limit,
                     or the page that could say "busy, retry in N s" is
                     the one that never loads (default: skip nothing)

    * `:soft`      — fraction of `:limit` after which responses carry
                     `x-slow-down: <seconds>` (default 0.8). It asks the
                     client to space its requests *before* the hard 429;
                     the web client does (`web/src/lib/busy.ts`)
    * `:strikes`   — how many 429s one peer may collect within
                     `:strike_window_ms` before it is put in the penalty
                     box for up to `:ban_ms` (Hammer's windows are aligned, so a ban
                     started late in one ends with it): every counted request answers 429
                     (reason `penalty`) until the ban runs out. For the
                     origin that was asked to slow down and did not.
                     Default `nil` — no penalty box. The shell still passes
                     (see `:skip_if`): a banned browser gets the page that
                     explains, not a blank one.

  Example:

      plug SukhiFedi.Web.RateLimitPlug, bucket: "inbox", limit: 300, scale_ms: 60_000
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts) do
    %{
      limit: Keyword.get(opts, :limit, 100),
      scale_ms: Keyword.get(opts, :scale_ms, 60_000),
      bucket: Keyword.get(opts, :bucket, "rl"),
      skip_prefixes: Keyword.get(opts, :skip_prefixes, []),
      skip_if: Keyword.get(opts, :skip_if, fn _conn -> false end),
      soft: Keyword.get(opts, :soft, 0.8),
      strikes: Keyword.get(opts, :strikes),
      strike_window_ms: Keyword.get(opts, :strike_window_ms, 600_000),
      ban_ms: Keyword.get(opts, :ban_ms, 900_000)
    }
  end

  @impl true
  def call(conn, %{skip_prefixes: skip, skip_if: skip_if} = opts) do
    if Enum.any?(skip, &String.starts_with?(conn.request_path, &1)) or skip_if.(conn),
      do: conn,
      else: limit(conn, opts)
  end

  defp limit(conn, %{bucket: bucket} = opts) do
    id = peer_id(conn)

    case banned_for(bucket, id, opts) do
      nil -> count(conn, bucket, id, opts)
      seconds -> deny(conn, bucket, "penalty", seconds)
    end
  end

  defp count(conn, bucket, id, %{limit: limit, scale_ms: scale_ms, soft: soft} = opts) do
    key = "#{bucket}:#{id}"

    case Hammer.check_rate(key, scale_ms, limit) do
      {:allow, n} when n > limit * soft ->
        put_resp_header(conn, "x-slow-down", Integer.to_string(window_left(key, scale_ms, limit)))

      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        strike(bucket, id, opts)
        deny(conn, bucket, "limit", div(scale_ms, 1_000))
    end
  end

  # The body carries `retry_after` too (as api's TokenRateLimit does): the
  # web client reads one place, not a header some proxies drop.
  defp deny(conn, bucket, reason, retry_after) do
    :telemetry.execute([:sukhi_fedi, :rate_limit, :deny], %{count: 1}, %{
      bucket: bucket,
      reason: reason
    })

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_content_type("application/json")
    |> send_resp(429, JSON.encode!(denial_body(reason, retry_after)))
    |> halt()
  end

  # `kind` tells the two 429s apart for a program. `reason` is words for a
  # person, only for the penalty box (the web client may show it as is).
  @penalty_reason "おいたはダメだよ〜"
  defp denial_body("penalty", retry_after),
    do: %{
      error: "rate_limited",
      kind: "penalty",
      reason: @penalty_reason,
      retry_after: retry_after
    }

  defp denial_body(_limit, retry_after),
    do: %{error: "rate_limited", kind: "limit", retry_after: retry_after}

  # Seconds until this peer's window turns over (at least 1).
  defp window_left(key, scale_ms, limit) do
    {:ok, {_count, _left, ms_to_next, _, _}} = Hammer.inspect_bucket(key, scale_ms, limit)
    max(1, ceil_div(ms_to_next, 1_000))
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  # ── the penalty box ──
  # Two more buckets per peer, both Hammer's: `strike` counts 429s in a
  # window; going over puts a one-hit `ban` bucket in place, whose window
  # *is* the ban — it expires on its own, no sweeper.
  defp strike(_bucket, _id, %{strikes: nil}), do: :ok

  defp strike(bucket, id, %{strikes: strikes, strike_window_ms: window, ban_ms: ban_ms}) do
    case Hammer.check_rate("#{bucket}:strike:#{id}", window, strikes) do
      {:allow, _} -> :ok
      {:deny, _} -> Hammer.check_rate_inc("#{bucket}:ban:#{id}", ban_ms, 1, 1)
    end

    :ok
  end

  defp banned_for(_bucket, _id, %{strikes: nil}), do: nil

  defp banned_for(bucket, id, %{ban_ms: ban_ms}) do
    case Hammer.inspect_bucket("#{bucket}:ban:#{id}", ban_ms, 1) do
      {:ok, {n, _, ms_to_next, _, _}} when n >= 1 -> max(1, ceil_div(ms_to_next, 1_000))
      _ -> nil
    end
  end

  @doc """
  The requester's identity for rate buckets, and the one definition of
  "the client's IP". Public because other gates (`Auth.MailIpGate`, the
  access log, the session-device fingerprint) must read the same notion
  of "who" — two definitions of the client IP would drift.

  cloudflared is the sole ingress and Cloudflare's edge sets (and
  overwrites any client-supplied) `cf-connecting-ip` with the real
  client IP, so prefer it. Without this the socket peer is the tunnel
  container — identical for every external request — collapsing the
  whole instance into one bucket (no per-IP isolation, /login
  credential-stuffing rides under one shared ceiling).
  """
  def peer_id(%Plug.Conn{} = conn) do
    case get_req_header(conn, "cf-connecting-ip") do
      [ip | _] when is_binary(ip) and ip != "" -> ip
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
