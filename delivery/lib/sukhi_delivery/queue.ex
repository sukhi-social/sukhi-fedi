# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Queue do
  @moduledoc """
  Where the delivery job queues live: PostgreSQL, through
  `SukhiDelivery.QueueRepo`, driven by `SukhiDelivery.Oban`.

  The gateway's Oban (`SukhiFedi.Oban`) uses the same database and the same
  `oban_jobs` table, with queues of its own. Each node runs only the queues
  its own config names, so a job one node inserts for the other's queue is
  picked up there.

  The business rows are in hosigraph, so the outbox row and its dispatch job
  are in different stores and the hop between them is at-least-once:
  `enqueued_outbox_ids/1` lets the relay skip rows already queued after a
  crash between the two writes, and `Delivery.Worker` absorbs any remaining
  duplicate via `delivery_receipts`.
  """

  import Ecto.Query

  alias SukhiDelivery.QueueRepo

  @doc "The Oban instance that owns this node's queues."
  @spec oban() :: atom()
  def oban, do: SukhiDelivery.Oban

  @doc """
  Oban instance for jobs this node writes and the gateway runs
  (`outbound_archive` …). One database, so our own instance reaches them.
  """
  @spec gateway_oban() :: atom()
  def gateway_oban, do: SukhiDelivery.Oban

  @doc "Insert a batch of job changesets into the delivery queue."
  @spec insert_all([Ecto.Changeset.t()]) :: [Oban.Job.t()]
  def insert_all(changesets), do: Oban.insert_all(oban(), changesets)

  @doc "Children, in start order: the connection, the tables, then Oban."
  @spec children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def children do
    [
      QueueRepo,
      SukhiDelivery.Queue.Migrate,
      {Oban, [name: SukhiDelivery.Oban] ++ Application.fetch_env!(:sukhi_delivery, Oban)}
    ]
  end

  @doc """
  The subset of `outbox_ids` that already have a dispatch job (any state).
  The job insert and the outbox flip are two stores, so a crash between them
  leaves rows `pending` that are already queued; they only need the flip.
  """
  @spec enqueued_outbox_ids([integer()]) :: [integer()]
  def enqueued_outbox_ids([]), do: []

  def enqueued_outbox_ids(outbox_ids) do
    worker = Oban.Worker.to_string(SukhiDelivery.Outbox.DispatchWorker)

    from(j in Oban.Job,
      where: j.worker == ^worker,
      where: fragment("(? ->> 'outbox_id')::bigint = ANY(?)", j.args, type(^outbox_ids, {:array, :integer})),
      select: fragment("(? ->> 'outbox_id')::bigint", j.args)
    )
    |> QueueRepo.all()
  end
end
