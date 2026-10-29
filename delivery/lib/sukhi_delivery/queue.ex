# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Queue do
  @moduledoc """
  Where the delivery job queues live.

  Default (`:postgres`): every queue is on `SukhiDelivery.Oban`, as before.

  `DELIVERY_QUEUE=sqlite`: the high-volume queues (`delivery`,
  `outbox_dispatch`) move to a single-node SQLite file driven by Oban's Lite
  engine (`SukhiDelivery.QueueOban` over `SukhiDelivery.QueueRepo`). The other
  queues and all business data stay in Postgres. This is the only place that
  knows which backend is active; callers use `insert_all/1` and `oban/0`.

  `SUKHI_STORE=datalevin` has no Postgres at all, so it implies the SQLite
  backend for *every* queue: there is no second Oban to leave any of them in.

  Because the outbox row (Postgres) and its dispatch job (SQLite) are in
  different stores, the hop is at-least-once: `enqueued_outbox_ids/1` lets the
  relay skip rows already queued after a crash between the two writes, and
  `Delivery.Worker` absorbs any remaining duplicate via `delivery_receipts`.
  """

  import Ecto.Query

  alias SukhiDelivery.QueueRepo

  @sqlite_queues [:delivery, :outbox_dispatch]

  @doc "Is the business data in Datalevin? Then there is no Postgres for Oban."
  @spec datalevin?() :: boolean()
  def datalevin?, do: Application.get_env(:sukhi_delivery, :store, :postgres) == :datalevin

  @spec backend() :: :postgres | :sqlite
  def backend do
    if datalevin?(),
      do: :sqlite,
      else: Application.get_env(:sukhi_delivery, :queue_backend, :postgres)
  end

  @doc "Oban instance that owns the high-volume queues."
  @spec oban() :: atom()
  def oban do
    if backend() == :sqlite, do: SukhiDelivery.QueueOban, else: SukhiDelivery.Oban
  end

  @doc """
  Oban instance that drains the gateway's queues (`outbound_archive` …), for
  jobs this node writes and the gateway runs. Postgres: the same database, so
  our own instance reaches them. Datalevin: the gateway's Oban keeps its own
  queue file, so we insert there (the combined release has both).
  """
  @spec gateway_oban() :: atom()
  def gateway_oban, do: if(datalevin?(), do: SukhiFedi.Oban, else: SukhiDelivery.Oban)

  @doc "Insert a batch of job changesets into the active delivery queue."
  @spec insert_all([Ecto.Changeset.t()]) :: [Oban.Job.t()]
  def insert_all(changesets), do: Oban.insert_all(oban(), changesets)

  @doc "The Postgres Oban, when there is a Postgres: all of it, or what the SQLite queue leaves."
  @spec postgres_children() :: [Supervisor.child_spec() | {module(), term()}]
  def postgres_children do
    if datalevin?(),
      do: [],
      else: [{Oban, [name: SukhiDelivery.Oban] ++ postgres_oban_config()}]
  end

  @doc "Supervisor children for the SQLite queue; empty on the Postgres backend."
  @spec children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def children do
    if backend() == :sqlite do
      [
        QueueRepo,
        SukhiDelivery.Queue.Migrate,
        SukhiDelivery.Queue.Handover,
        {Oban, [name: SukhiDelivery.QueueOban] ++ sqlite_oban_config()}
      ]
    else
      []
    end
  end

  @doc """
  The Postgres Oban config, minus `outbox_dispatch` (only the relay writes
  it). `delivery` stays: the gateway inserts `Delivery.Worker` jobs for
  follows, quotes and relays into Postgres, so that queue is drained on both
  stores.
  """
  @spec postgres_oban_config() :: keyword()
  def postgres_oban_config do
    config = Application.fetch_env!(:sukhi_delivery, Oban)

    if backend() == :sqlite do
      Keyword.update!(config, :queues, &Keyword.delete(&1, :outbox_dispatch))
    else
      config
    end
  end

  defp sqlite_oban_config do
    all = Application.fetch_env!(:sukhi_delivery, Oban)[:queues]
    queues = if datalevin?(), do: all, else: Keyword.take(all, @sqlite_queues)

    max_age = Application.get_env(:sukhi_delivery, :queue_retention_seconds, 30 * 24 * 60 * 60)

    [
      engine: Oban.Engines.Lite,
      repo: QueueRepo,
      queues: queues,
      plugins: [
        {Oban.Plugins.Pruner, max_age: max_age},
        {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(15)}
      ]
    ]
  end

  @doc """
  The subset of `outbox_ids` that already have a dispatch job in the SQLite
  queue (any state). Always `[]` on the Postgres backend, where the job insert
  and the outbox flip share a transaction.
  """
  @spec enqueued_outbox_ids([integer()]) :: [integer()]
  def enqueued_outbox_ids(outbox_ids) do
    if backend() == :sqlite and outbox_ids != [] do
      worker = Oban.Worker.to_string(SukhiDelivery.Outbox.DispatchWorker)

      from(j in Oban.Job,
        where: j.worker == ^worker,
        where: fragment("json_extract(?, '$.outbox_id')", j.args) in ^outbox_ids,
        select: fragment("json_extract(?, '$.outbox_id')", j.args)
      )
      |> QueueRepo.all()
    else
      []
    end
  end
end
