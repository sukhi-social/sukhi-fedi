# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.MetricsController do
  @moduledoc """
  Token-guarded metrics, in two shapes. Distinct from the public viewer
  SSE stream, which carries only what the front page already shows.

  Auth is a single dedicated bearer — `config :sukhi_fedi, :metrics_token`,
  set from `METRICS_TOKEN` in prod. Machine-to-machine, so it stays out
  of the OAuth user-token system entirely. No token configured → the
  endpoint 404s (feature off), exactly like the nodeinfo-monitor routes.

  JSON, for offline analysis (Julia → anomaly baselines, capacity
  forecasting):

    * `GET /api/metrics` — one live host snapshot (same source as the
      SSE card, returned once).
    * `GET /api/metrics?since=<unix>[&until=<unix>][&limit=<n>]` — the
      stored time series in that window, oldest first.

  Prometheus scrape format:

    * `GET /metrics` — PromEx output, behind the same bearer.

  `/metrics` used to be open. It carries no personal data, but it does
  hand over the exact version of every dependency, the internal database
  host and name, every table name, and the shape of the load — which is
  the homework someone looking for a known vulnerability would otherwise
  have to do themselves. Nothing there is worth being public, so it is
  closed by default now: an operator who wants a scraper points it here
  with the bearer. See `docs/web-surface.md`.
  """

  import Plug.Conn

  alias SukhiFedi.Metrics
  alias SukhiFedi.SystemMetrics

  def show(conn, _opts) do
    case authorize(conn) do
      :off -> send_json(conn, 404, %{error: "not_found"})
      :unauthorized -> send_json(conn, 401, %{error: "unauthorized"})
      :ok -> serve(conn)
    end
  end

  # `GET /metrics` — the Prometheus scrape. Same bearer as the JSON above,
  # so there is one answer to "who may read this host's telemetry".
  def prometheus(conn, _opts) do
    case authorize(conn) do
      :off -> send_json(conn, 404, %{error: "not_found"})
      :unauthorized -> send_json(conn, 401, %{error: "unauthorized"})
      :ok -> PromEx.Plug.call(conn, PromEx.Plug.init(prom_ex_module: SukhiFedi.PromEx))
    end
  end

  defp serve(conn) do
    case window(conn.query_params) do
      {:ok, nil} ->
        send_json(conn, 200, live_snapshot())

      {:ok, opts} ->
        samples = Metrics.history(opts) |> Enum.map(&jsonify_sample/1)
        send_json(conn, 200, %{samples: samples, count: length(samples)})

      {:error, msg} ->
        send_json(conn, 400, %{error: "bad_request", detail: msg})
    end
  end

  # ── auth ───────────────────────────────────────────────────────────────────

  defp authorize(conn) do
    case Application.get_env(:sukhi_fedi, :metrics_token) do
      token when is_binary(token) and token != "" ->
        if token_matches?(presented_token(conn), token), do: :ok, else: :unauthorized

      _ ->
        :off
    end
  end

  defp presented_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      _ -> ""
    end
  end

  # Constant-time, length-safe (secure_compare returns false on length
  # mismatch rather than leaking it through an early return).
  defp token_matches?(presented, expected),
    do: Plug.Crypto.secure_compare(presented, expected)

  # ── query parsing ────────────────────────────────────────────────────────

  # No `since` → live snapshot (nil opts). With `since`, build the
  # history options, treating each numeric param as unix seconds.
  defp window(%{"since" => _} = params) do
    with {:ok, since} <- unix_param(params, "since"),
         {:ok, until} <- unix_param(params, "until"),
         {:ok, limit} <- int_param(params, "limit") do
      opts =
        [since: since, until: until, limit: limit]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      {:ok, opts}
    end
  end

  defp window(_params), do: {:ok, nil}

  defp unix_param(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      raw ->
        case Integer.parse(raw) do
          {secs, ""} -> {:ok, DateTime.from_unix!(secs)}
          _ -> {:error, "#{key} must be a unix timestamp (seconds)"}
        end
    end
  end

  defp int_param(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      raw ->
        case Integer.parse(raw) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "#{key} must be a positive integer"}
        end
    end
  end

  # ── rendering ──────────────────────────────────────────────────────────────

  defp live_snapshot do
    snap = SystemMetrics.snapshot()

    %{
      cpu: snap.cpu,
      memory: snap.memory,
      load: snap.load,
      disk: snap.disk,
      beam: snap.beam,
      outbox_dlq_depth: Metrics.dlq_depth(),
      ts: System.system_time(:second)
    }
  end

  defp jsonify_sample(%{sampled_at: at} = row),
    do: %{row | sampled_at: DateTime.to_iso8601(at)}

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
