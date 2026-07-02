# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SukhiFedi.Addon.Registry.verify_abi!()

    core_children = [
      SukhiFedi.PromEx,
      SukhiFedi.Repo,
      {Bandit, plug: SukhiFedi.Web.Router, port: 4000},
      {Gnat.ConnectionSupervisor, nats_connection_settings()},
      SukhiFedi.Cache.Ets,
      # Finch powers outbound HTTP from the federation fetcher and the
      # nodeinfo-monitor addon. Outbound ActivityPub delivery lives on
      # the separate delivery node; this pool does not carry that traffic.
      {Finch,
       name: SukhiFedi.Finch,
       pools: %{
         default: [size: 50, count: 4]
       }},
      # Native fedify.*.v1 NATS service (SukhiFedi.Fedi) — replaces the
      # Bun sidecar. It shares the `fedify-workers` queue group with any
      # Bun replica still running, so cutover is "stop the bun container".
      # After Cache.Ets (key cache) and Finch (remote fetch).
      {Gnat.ConsumerSupervisor, fedi_consumer_settings()},
      {Oban, [name: SukhiFedi.Oban] ++ Application.fetch_env!(:sukhi_fedi, Oban)},
      # Records one host-resource row per interval into metric_samples so
      # the series accrues for offline analysis. :ignore (no-op) unless
      # :metrics sample_interval_ms is set — the test env leaves it off.
      SukhiFedi.Metrics.Sampler,
      # Holds the latest L4 telemetry snapshot the WebTransport edge relay
      # (wt-relay, x64) publishes over NATS, for the /admin/system page. After
      # the Gnat connection above; subscribes lazily and retries if NATS isn't
      # up yet, so it never blocks boot.
      SukhiFedi.WtRelayTelemetry
    ]

    children = core_children ++ SukhiFedi.Addon.Registry.children()

    opts = [strategy: :one_for_one, name: SukhiFedi.Supervisor]
    result = Supervisor.start_link(children, opts)

    # rustfs accessory might not be reachable yet on the very first boot,
    # so do this fire-and-forget. ensure_bucket/0 logs failures and is
    # idempotent.
    Task.start(fn -> SukhiFedi.Addons.Media.Bootstrap.ensure_bucket() end)

    result
  end

  defp fedi_consumer_settings do
    %{
      connection_name: :gnat,
      module: SukhiFedi.Fedi.Service,
      subscription_topics: [
        %{topic: "fedify.>", queue_group: "fedify-workers"}
      ]
    }
  end

  defp nats_connection_settings do
    nats_cfg = Application.get_env(:sukhi_fedi, :nats, [])
    host = Keyword.get(nats_cfg, :host, "127.0.0.1")
    port = Keyword.get(nats_cfg, :port, 4222)

    %{
      name: :gnat,
      connection_settings: [
        %{host: host, port: port}
      ]
    }
  end
end
