# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Workers do
  @moduledoc """
  The recurring jobs of the graph, as Oban workers on the `:maintenance`
  queue (cron entries come from `crontab/0`, added only when the graph is on).

    * `Tokens`  — every few minutes: segment what has no tokens yet.
    * `Sweep`   — daily: capacity cleanup. **Dry-run unless
      `SUKHI_GRAPH_SWEEP=execute`**: the report is logged, nothing is deleted
      until someone has read one. Then blob GC.

  Knobs (all environment, read here): `SUKHI_GRAPH_TTL_FOLLOWED_DAYS` (90),
  `SUKHI_GRAPH_TTL_OTHER_DAYS` (14), `SUKHI_GRAPH_SWEEP_LIMIT` (2000),
  `SUKHI_GRAPH_SIZE_BUDGET_MB` (unset = no budget). Over budget, the TTLs
  halve for that run (`ttls/2`).
  """

  @doc "Cron entries for `Oban.Plugins.Cron`."
  @spec crontab() :: [{String.t(), module()}]
  def crontab, do: [{"*/5 * * * *", __MODULE__.Tokens}, {"40 3 * * *", __MODULE__.Sweep}]

  @day 86_400

  @doc "TTLs in seconds `{followed, other}`; halved once when the graph exceeds its size budget."
  @spec ttls(%{optional(String.t()) => String.t()}, non_neg_integer()) ::
          {pos_integer(), pos_integer()}
  def ttls(env, size_bytes) do
    followed = days(env, "SUKHI_GRAPH_TTL_FOLLOWED_DAYS", 90) * @day
    other = days(env, "SUKHI_GRAPH_TTL_OTHER_DAYS", 14) * @day

    case Integer.parse(Map.get(env, "SUKHI_GRAPH_SIZE_BUDGET_MB", "")) do
      {mb, ""} when mb > 0 and size_bytes > mb * 1_048_576 ->
        {max(div(followed, 2), @day), max(div(other, 2), @day)}

      _ ->
        {followed, other}
    end
  end

  defp days(env, name, default) do
    case Integer.parse(Map.get(env, name, "")) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defmodule Tokens do
    @moduledoc false
    use Oban.Worker, queue: :maintenance, max_attempts: 1, unique: [period: 240]

    require Logger

    @impl Oban.Worker
    def perform(_job) do
      report = SukhiFedi.Graph.Tokens.run(limit: 500)
      if report.done > 0 or report.stopped, do: Logger.info("graph tokens: #{inspect(report)}")
      :ok
    end
  end

  defmodule Sweep do
    @moduledoc false
    use Oban.Worker, queue: :maintenance, max_attempts: 1, unique: [period: 3600]

    require Logger

    @impl Oban.Worker
    def perform(_job) do
      env = System.get_env()
      {followed, other} = SukhiFedi.Graph.Workers.ttls(env, dir_bytes())
      mode = if env["SUKHI_GRAPH_SWEEP"] == "execute", do: :execute, else: :dry_run

      limit =
        case Integer.parse(env["SUKHI_GRAPH_SWEEP_LIMIT"] || "") do
          {n, ""} when n > 0 -> n
          _ -> 2000
        end

      report =
        SukhiFedi.Graph.Sweep.run(mode,
          ttl_followed_s: followed,
          ttl_other_s: other,
          limit: limit
        )

      Logger.info("graph sweep: #{inspect(report)}")

      if mode == :execute, do: Logger.info("graph gc: #{inspect(SukhiFedi.Graph.Sweep.gc())}")
      :ok
    end

    defp dir_bytes do
      dir = Path.join(SukhiFedi.Datalevin.Config.current().dir, "graph")

      for f <- Path.wildcard(Path.join(dir, "**/*")),
          File.regular?(f),
          reduce: 0,
          do: (acc -> acc + File.stat!(f).size)
    end
  end
end
