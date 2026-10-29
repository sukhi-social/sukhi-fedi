# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Queue do
  @moduledoc """
  Where the gateway's Oban keeps its jobs.

  With the default store, the Oban config is used as written (`SukhiFedi.Repo`,
  Postgres). With `SUKHI_STORE=datalevin` the same queues, cron entries and
  plugins run on Oban's Lite engine over `SukhiFedi.QueueRepo` (SQLite, one
  node), because the engine behind `SukhiFedi.Repo` is not a SQL database.
  Jobs are therefore *not* in the same store as the business rows; the
  at-least-once consequences are the ones docs/DELIVERY_QUEUE_MIGRATION.md
  already describes for the SQLite delivery queue.
  """

  alias SukhiFedi.Store

  @doc "Children that must start before Oban: the queue file and its tables."
  @spec children() :: [Supervisor.child_spec() | module()]
  def children do
    if Store.datalevin?(), do: [SukhiFedi.QueueRepo, SukhiFedi.Queue.Migrate], else: []
  end

  @doc "The repo that holds this gateway's `oban_jobs`."
  @spec repo() :: module()
  def repo, do: if(Store.datalevin?(), do: SukhiFedi.QueueRepo, else: SukhiFedi.Repo)

  @doc "Every repo to read `oban_jobs` from: ours, and any extra queue store (the SQLite delivery queue in a combined release)."
  @spec job_repos() :: [module()]
  def job_repos, do: Enum.uniq([repo() | Application.get_env(:sukhi_fedi, :extra_job_repos, [])])

  @doc "The keyword list `{Oban, …}` is started with."
  @spec oban_config() :: keyword()
  def oban_config do
    config = Application.fetch_env!(:sukhi_fedi, Oban) |> with_graph_jobs()

    if Store.datalevin?(),
      do:
        Keyword.merge(config,
          engine: Oban.Engines.Lite,
          repo: SukhiFedi.QueueRepo,
          notifier: Oban.Notifiers.PG
        ),
      else: config
  end

  # The graph's recurring jobs ride the existing Cron plugin, only when the graph is on.
  defp with_graph_jobs(config) do
    if SukhiFedi.Graph.enabled?() do
      Keyword.update(config, :plugins, [], fn plugins ->
        Enum.map(plugins, fn
          {Oban.Plugins.Cron, opts} ->
            {Oban.Plugins.Cron,
             Keyword.update(opts, :crontab, [], &(&1 ++ SukhiFedi.Graph.Workers.crontab()))}

          other ->
            other
        end)
      end)
      |> Keyword.update(:queues, [maintenance: 1], &Keyword.put_new(&1, :maintenance, 1))
    else
      config
    end
  end
end
