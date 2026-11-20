# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SukhiDelivery.PromEx,
        SukhiDelivery.Repo,
        SukhiDelivery.Cache.Ets,
        # Pull Federation counters, folded into pull_stats in batches.
        {SukhiShared.PullStats, repo: SukhiDelivery.Repo},
        # Outbound HTTP pool for remote inbox POSTs. Tune via
        # `sukhi_delivery_pool_utilization` (stays near 1.0 → scale up).
        # Sizing comes from `:finch_pool` (see runtime.exs).
        {Finch,
         name: SukhiDelivery.Finch,
         pools: %{
           default: Application.get_env(:sukhi_delivery, :finch_pool, size: 50, count: 4)
         }}
      ] ++
        # The queue connection, its tables, then Oban: the relay below
        # enqueues as soon as it starts, so the queue has to be there first.
        SukhiDelivery.Queue.children() ++
        [
          # Outbox relay: turns `outbox` rows (written by the
          # gateway) into Oban dispatch jobs. The job then runs
          # FedifyClient.translate → Worker fan-out; routing lives in
          # SukhiDelivery.Outbox.Consumer.
          SukhiDelivery.Outbox.Relay
        ]

    children = nats_children() ++ children

    opts = [strategy: :one_for_one, name: SukhiDelivery.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Delivery's own NATS connection exists only to ask the fedify service
  # for translations (FedifyClient). When that service is in this VM (the
  # `combined` release names it), there is nothing to connect to.
  defp nats_children do
    if SukhiDelivery.Delivery.FedifyClient.local_service(),
      do: [],
      else: [{Gnat.ConnectionSupervisor, nats_connection_settings()}]
  end

  defp nats_connection_settings do
    nats_cfg = Application.get_env(:sukhi_delivery, :nats, [])
    host = Keyword.get(nats_cfg, :host, "127.0.0.1")
    port = Keyword.get(nats_cfg, :port, 4222)

    %{
      # Not :gnat — the gateway registers that name, and the combined
      # release runs both apps in one BEAM.
      name: :gnat_delivery,
      connection_settings: [
        %{host: host, port: port}
      ]
    }
  end
end
