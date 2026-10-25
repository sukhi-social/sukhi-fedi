# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PromEx.Load do
  @moduledoc """
  The metrics that say *where it clogs* — what Ecto, Oban and the BEAM
  plugins next to it do not already say.

  Those three cover the DB pool (`ecto_repo_query_queue_time`), the job
  queues and the run queue. What they cannot see is the request side, so
  three events are emitted by the code that owns each fact (one place
  each, as CODE_STYLE.md asks):

    * `[:sukhi_fedi, :http, :request]` — `AccessLogPlug`, once per
      response. Tags: route `group` (`Web.RouteGroup`) and `status`.
      Gives requests/s, p50/p95 by group, and the 429/503 share.
    * `[:sukhi_fedi, :rpc, :call]` — `PluginPlug`, around `:rpc.call`.
      Tags: `result` (`ok`, or the `badrpc` reason such as `timeout`).
      Duration bucketed up to the 5 s timeout: a pile in the top bucket
      is the "fails slowly" shape from the 0.5 OCPU test.
    * `[:sukhi_fedi, :rate_limit, :deny]` — `RateLimitPlug`. Tags `bucket` and `reason` (`limit`, or `penalty` for a peer in the penalty box).

  Read them with `GET /metrics` (bearer), or the load test's summary.
  """
  use PromEx.Plugin

  @request_buckets [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
  @rpc_buckets [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]

  @impl true
  def event_metrics(_opts) do
    Event.build(:sukhi_fedi_load_event_metrics, [
      distribution(
        [:sukhi_fedi, :http, :request, :duration, :milliseconds],
        event_name: [:sukhi_fedi, :http, :request],
        measurement: :duration,
        description: "Response time by route group and status.",
        reporter_options: [buckets: @request_buckets],
        tags: [:group, :status],
        unit: {:native, :millisecond}
      ),
      distribution(
        [:sukhi_fedi, :rpc, :call, :duration, :milliseconds],
        event_name: [:sukhi_fedi, :rpc, :call],
        measurement: :duration,
        description: "Gateway to plugin-node RPC time, by outcome.",
        reporter_options: [buckets: @rpc_buckets],
        tags: [:result],
        unit: {:native, :millisecond}
      ),
      counter(
        [:sukhi_fedi, :rate_limit, :deny, :total],
        event_name: [:sukhi_fedi, :rate_limit, :deny],
        description:
          "Requests turned away with 429, by limiter bucket and reason (limit | penalty).",
        tags: [:bucket, :reason]
      )
    ])
  end
end
