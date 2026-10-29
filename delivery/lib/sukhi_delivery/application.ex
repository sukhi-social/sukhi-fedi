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
        {Gnat.ConnectionSupervisor, nats_connection_settings()},
        # Outbound HTTP pool for remote inbox POSTs. Tune via
        # `sukhi_delivery_pool_utilization` (stays near 1.0 → scale up).
        # Sizing comes from `:finch_pool` (see runtime.exs).
        {Finch,
         name: SukhiDelivery.Finch,
         pools: %{
           default: Application.get_env(:sukhi_delivery, :finch_pool, size: 50, count: 4)
         }}
        # SQLite delivery queue (DELIVERY_QUEUE=sqlite); empty otherwise. Starts
        # before the Postgres Oban so enqueues never find the queue missing.
      ] ++
        SukhiDelivery.Queue.children() ++
        SukhiDelivery.Queue.postgres_children() ++
        [
          # Transactional Outbox relay: turns `outbox` rows (written by the
          # gateway) into Oban dispatch jobs — the job insert and the row's
          # flip to `published` share one transaction. The job then runs
          # FedifyClient.translate → Worker fan-out; routing lives in
          # SukhiDelivery.Outbox.Consumer.
          SukhiDelivery.Outbox.Relay
        ]

    opts = [strategy: :one_for_one, name: SukhiDelivery.Supervisor]
    Supervisor.start_link(children, opts)
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
