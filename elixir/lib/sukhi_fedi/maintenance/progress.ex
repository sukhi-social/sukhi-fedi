# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.Progress do
  @moduledoc """
  How a maintenance script tells `/admin` what it is doing.

  A script opens a run, steps it once per item, and closes it:

      run = Progress.start("refetch_actors", :execute, length(uris), "fetching")
      {results, run} = Progress.map(run, uris, &refetch/1)
      Progress.finish(run, summary)

  Each call hands back the updated run, which the script threads through.
  The count lives in that struct; the DB row (`maintenance_runs`) is written
  at most once per `@flush_ms`, however many items go by — the cost is paid
  per second, not per item. `start/4`, `stage/3`, `finish/2` and `fail/2`
  always write, so a stage change or the end is never lost to the throttle.

  Reporting is best-effort: if the write fails (DB hiccup) the script keeps
  going and the next flush catches up. A script is never held up by its
  own progress bar.

  An item "fails" when its result is `:error` or `{:error, _}`. `:skipped`
  (origin gone, nothing to change) is an ordinary outcome and not counted.
  """

  import Ecto.Query
  require Logger

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.MaintenanceRun

  @flush_ms 1_000
  @max_error_len 500

  defstruct [:id, :done, :failed, :last_error, :flushed_at]

  @type t :: %__MODULE__{}

  @doc "Open a run. `total` may be 0 when the script cannot count ahead."
  @spec start(String.t(), atom(), non_neg_integer(), String.t() | nil) :: t()
  def start(name, mode, total, stage \\ nil) when is_binary(name) do
    now = now()

    {:ok, row} =
      Repo.insert(%MaintenanceRun{
        name: name,
        mode: to_string(mode),
        state: "running",
        stage: stage,
        total: total,
        started_at: now,
        updated_at: now
      })

    %__MODULE__{id: row.id, done: 0, failed: 0, last_error: nil, flushed_at: mono()}
  end

  @doc "Count one finished item; `outcome` is the item's result. Throttled write."
  @spec step(t(), term()) :: t()
  def step(%__MODULE__{} = run, outcome) do
    run
    |> tally(outcome)
    |> maybe_flush()
  end

  @doc """
  Run `fun` over `items`, stepping once per item; returns `{results, run}`.
  `outcome` picks the part of a result that says whether the item failed
  (default: the result itself) for scripts that return richer shapes.
  """
  @spec map(t(), Enumerable.t(), (term() -> term()), (term() -> term())) :: {list(), t()}
  def map(%__MODULE__{} = run, items, fun, outcome \\ & &1)
      when is_function(fun, 1) and is_function(outcome, 1) do
    {rev, run} =
      Enum.reduce(items, {[], run}, fn item, {acc, run} ->
        result = fun.(item)
        {[result | acc], step(run, outcome.(result))}
      end)

    {Enum.reverse(rev), run}
  end

  @doc "Move to a new stage (with its own item count) and write straight away."
  @spec stage(t(), String.t(), non_neg_integer()) :: t()
  def stage(%__MODULE__{} = run, stage, total) when is_binary(stage) do
    run = %{run | done: 0}
    write(run, stage: stage, total: total)
  end

  @doc "Close the run as finished. `summary` is shown as-is, so keep it small."
  @spec finish(t(), map()) :: t()
  def finish(%__MODULE__{} = run, summary \\ %{}) do
    write(run, state: "done", finished_at: now(), summary: jsonable(summary))
  end

  @doc "Close the run as stopped by an exception, with the reason."
  @spec fail(t(), term()) :: t()
  def fail(%__MODULE__{} = run, reason) do
    write(run, state: "failed", finished_at: now(), last_error: clip(reason))
  end

  @doc """
  Wrap a whole run: closes it as failed (and re-raises) if `fun` raises, as
  finished with the returned summary otherwise. For scripts whose body is
  not a single item loop.
  """
  @spec track(String.t(), atom(), non_neg_integer(), String.t() | nil, (t() -> {map(), t()})) ::
          map()
  def track(name, mode, total, stage, fun) when is_function(fun, 1) do
    run = start(name, mode, total, stage)

    try do
      {summary, run} = fun.(run)
      finish(run, summary)
      summary
    rescue
      e ->
        fail(run, Exception.message(e))
        reraise e, __STACKTRACE__
    end
  end

  # ── reading (for /admin) ────────────────────────────────────────────────

  @doc "Newest runs first."
  @spec recent(pos_integer()) :: [MaintenanceRun.t()]
  def recent(limit \\ 10) do
    Repo.all(from(r in MaintenanceRun, order_by: [desc: r.started_at, desc: r.id], limit: ^limit))
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp tally(run, outcome) do
    case failure_reason(outcome) do
      nil -> %{run | done: run.done + 1}
      reason -> %{run | done: run.done + 1, failed: run.failed + 1, last_error: clip(reason)}
    end
  end

  defp failure_reason(:error), do: "error"
  defp failure_reason({:error, reason}), do: reason
  defp failure_reason(_), do: nil

  defp maybe_flush(run) do
    case mono() - run.flushed_at >= @flush_ms do
      true -> write(run, [])
      false -> run
    end
  end

  # The counters always ride along, so a write is also a heartbeat.
  defp write(run, extra) do
    set =
      Keyword.merge(
        [done: run.done, failed: run.failed, last_error: run.last_error, updated_at: now()],
        extra
      )

    try do
      {_, _} = Repo.update_all(from(r in MaintenanceRun, where: r.id == ^run.id), set: set)
    rescue
      e -> Logger.warning("maintenance progress write failed: #{Exception.message(e)}")
    end

    %{run | flushed_at: mono()}
  end

  # Summaries carry atoms and tuples; the column is JSON.
  defp jsonable(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), jsonable_value(v)} end)
  end

  defp jsonable_value(%{} = m), do: jsonable(m)
  defp jsonable_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp jsonable_value(v) when is_atom(v), do: Atom.to_string(v)
  defp jsonable_value(v) when is_list(v) and length(v) > 20, do: "#{length(v)} item(s)"
  defp jsonable_value(v) when is_list(v), do: Enum.map(v, &jsonable_value/1)
  defp jsonable_value(v), do: inspect(v)

  defp clip(reason) when is_binary(reason), do: String.slice(reason, 0, @max_error_len)
  defp clip(reason), do: reason |> inspect() |> clip()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp mono, do: System.monotonic_time(:millisecond)
end
