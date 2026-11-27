# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Queue do
  @moduledoc """
  Where the delivery job queues live: PostgreSQL, through
  `SukhiDelivery.QueueRepo`, driven by `SukhiDelivery.Oban`.

  The gateway's Oban (`SukhiFedi.Oban`) uses the same database and the same
  `oban_jobs` table, with queues of its own. Each node runs only the queues
  its own config names, so a job one node inserts for the other's queue is
  picked up there.

  The gateway's `outbox` rows are in this database too, so
  `Outbox.Relay` queues a dispatch job and marks its row in one
  transaction. A send that runs twice is absorbed by `Delivery.Worker`
  via `delivery_receipts`.
  """

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
end
