# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Queue do
  @moduledoc """
  Where the gateway's Oban keeps its jobs: PostgreSQL, through
  `SukhiFedi.QueueRepo`.

  The business rows are in Datalevin (`SukhiFedi.Repo`), so a job is never in
  the same store as the row that caused it. A job insert and a Datalevin write
  cannot share a transaction; callers write the row first and enqueue after,
  and a job that runs twice must be harmless (`delivery_receipts` for sends).

  The delivery node's Oban (`SukhiDelivery.Oban`) uses the same database and
  the same `oban_jobs` table, with queues of its own; each node runs only the
  queues named in its own config, so a job inserted here for a delivery queue
  is picked up there.
  """

  @doc "Children that must start before Oban: the connection, and the tables."
  @spec children() :: [module()]
  def children, do: [SukhiFedi.QueueRepo, SukhiFedi.Queue.Migrate]

  @doc "The repo that holds `oban_jobs`."
  @spec repo() :: module()
  def repo, do: SukhiFedi.QueueRepo

  @doc "Every repo to read `oban_jobs` from. One database holds every queue, so this is one repo; callers loop over a list."
  @spec job_repos() :: [module()]
  def job_repos, do: [repo()]

  @doc "The keyword list `{Oban, …}` is started with."
  @spec oban_config() :: keyword()
  def oban_config, do: Application.fetch_env!(:sukhi_fedi, Oban)
end
