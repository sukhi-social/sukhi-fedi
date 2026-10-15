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
      skip_prefixes: Keyword.get(opts, :skip_prefixes, [])
    }
  end

  @impl true
  def call(conn, %{skip_prefixes: skip} = opts) do
    if Enum.any?(skip, &String.starts_with?(conn.request_path, &1)),
      do: conn,
      else: limit(conn, opts)
  end

  defp limit(conn, %{limit: limit, scale_ms: scale_ms, bucket: bucket}) do
    key = "#{bucket}:#{peer_id(conn)}"

    case Hammer.check_rate(key, scale_ms, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(scale_ms, 1_000)))
        |> put_resp_content_type("application/json")
        |> send_resp(429, JSON.encode!(%{error: "rate_limited"}))
        |> halt()
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
