# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.ServerActivity do
  @moduledoc """
  "What is the server doing right now?" — the read side of the `/admin`
  landing page.

  One `snapshot/0` gathers, in a handful of grouped queries (never one per
  row):

    * `maintenance` — runs reported by `SukhiFedi.Maintenance.Progress`:
      the ones still going, and the ones that ended in the last day;
    * `queues` — Oban jobs by queue and state (`oban_jobs` is shared with
      the delivery node, so this also shows delivery and federation work);
    * `outbox` — domain events waiting to be handed to NATS;
    * `failures` — Oban jobs that gave up in the last day, newest first,
      with the last error each one recorded;
    * `backfill` — follow-backfill state counts (see `/admin/backfill`).

  Read-only and cheap enough to poll every few seconds. A part that cannot
  be read (say `oban_jobs` is missing on a fresh database) comes back as
  `nil`/empty rather than failing the page; the page says it could not look.
  """

  import Ecto.Query
  require Logger

  alias SukhiFedi.Federation.OutboxBackfill
  alias SukhiFedi.Maintenance.Progress
  alias SukhiFedi.Repo

  # A running run whose row has not been touched for this long is shown as
  # "may have stopped". Progress writes about once a second, so this is
  # generous — a long single statement (WipeRemote) is the slow case.
  @stale_after_s 180
  @active_states ~w(executing available scheduled retryable)
  @recent_s 24 * 3600
  @failure_limit 8

  @spec snapshot(DateTime.t()) :: map()
  def snapshot(now \\ DateTime.utc_now()) do
    runs = Progress.recent(12)
    cutoff = DateTime.add(now, -@recent_s, :second)

    {running, ended} = Enum.split_with(runs, &(&1.state == "running"))

    %{
      now: now,
      maintenance: %{
        running: Enum.map(running, &with_staleness(&1, now)),
        ended: Enum.filter(ended, &recent?(&1, cutoff))
      },
      queues: queues(cutoff),
      outbox: outbox(now),
      failures: failures(cutoff),
      backfill: OutboxBackfill.counts()
    }
  end

  @doc "True when the server has nothing running, queued, or failed to show."
  @spec quiet?(map()) :: boolean()
  def quiet?(%{} = s) do
    s.maintenance.running == [] and s.failures == [] and
      Enum.all?(s.queues || [], &(&1.executing + &1.available + &1.retryable == 0))
  end

  @scripts %{
    "refetch_actors" => "RefetchActors",
    "rebuild_from_archive" => "RebuildFromArchive",
    "rebuild_remote_notes" => "RebuildRemoteNotes",
    "rebuild_remote_note_ids" => "RebuildRemoteNoteIds",
    "rebuild_direct_visibility" => "RebuildDirectVisibility",
    "wipe_remote" => "WipeRemote"
  }

  @doc "The command to run a script again, or nil for a name we do not know."
  @spec rerun_command(String.t()) :: String.t() | nil
  def rerun_command(name) do
    case @scripts do
      %{^name => mod} -> "bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.#{mod}.run(:execute)'"
      _ -> nil
    end
  end

  @doc "Percent done (0..100), or nil when the script could not count ahead."
  @spec percent(%{total: integer(), done: integer()}) :: non_neg_integer() | nil
  def percent(%{total: total}) when total <= 0, do: nil
  def percent(%{total: total, done: done}), do: min(100, div(done * 100, total))

  @doc "Rough seconds left from the pace so far, or nil while there is nothing to go on."
  @spec eta_s(map(), DateTime.t()) :: non_neg_integer() | nil
  def eta_s(%{done: done, total: total}, _now) when done <= 0 or total <= done, do: nil

  def eta_s(%{done: done, total: total, started_at: started}, now) do
    elapsed = max(DateTime.diff(now, started, :second), 1)
    div(elapsed * (total - done), done)
  end

  defp with_staleness(run, now) do
    quiet_s = DateTime.diff(now, run.updated_at, :second)
    Map.put(run, :stale?, quiet_s > @stale_after_s)
  end

  defp recent?(%{finished_at: nil}, _cutoff), do: false
  defp recent?(%{finished_at: at}, cutoff), do: DateTime.compare(at, cutoff) == :gt

  # [%{queue:, executing:, available:, scheduled:, retryable:}] — one query.
  defp queues(cutoff) do
    rows =
      from(j in "oban_jobs",
        where:
          j.state in ^@active_states or (j.state == "discarded" and j.discarded_at > ^cutoff),
        group_by: [j.queue, j.state],
        select: {j.queue, j.state, count(j.id)}
      )
      |> SukhiFedi.Queue.repo().all()

    rows
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {queue, entries} ->
      by_state = Map.new(entries, fn {_q, state, n} -> {state, n} end)

      %{
        queue: queue,
        executing: Map.get(by_state, "executing", 0),
        available: Map.get(by_state, "available", 0),
        scheduled: Map.get(by_state, "scheduled", 0),
        retryable: Map.get(by_state, "retryable", 0),
        discarded: Map.get(by_state, "discarded", 0)
      }
    end)
    |> Enum.sort_by(& &1.queue)
  rescue
    e -> unreadable("queues", e, nil)
  end

  defp outbox(now) do
    rows =
      from(o in "outbox",
        where: o.status in ["pending", "failed"],
        group_by: o.status,
        select: {o.status, count(o.id), min(o.inserted_at)}
      )
      |> Repo.all()
      |> Map.new(fn {status, n, oldest} -> {status, {n, oldest}} end)

    {pending, oldest} = Map.get(rows, "pending", {0, nil})
    {failed, _} = Map.get(rows, "failed", {0, nil})

    %{pending: pending, failed: failed, oldest_pending_s: age_s(oldest, now)}
  rescue
    e -> unreadable("outbox", e, nil)
  end

  defp failures(cutoff) do
    from(j in "oban_jobs",
      where: j.state == "discarded" and j.discarded_at > ^cutoff,
      order_by: [desc: j.discarded_at, desc: j.id],
      limit: @failure_limit,
      select: %{
        worker: j.worker,
        queue: j.queue,
        attempt: j.attempt,
        discarded_at: j.discarded_at,
        errors: j.errors
      }
    )
    |> SukhiFedi.Queue.repo().all()
    |> Enum.map(fn j ->
      %{
        worker: j.worker,
        queue: j.queue,
        attempt: j.attempt,
        discarded_at: utc(j.discarded_at),
        error: last_error(j.errors)
      }
    end)
  rescue
    e -> unreadable("failures", e, [])
  end

  defp last_error([_ | _] = errors), do: errors |> List.last() |> Map.get("error")
  defp last_error(_), do: nil

  defp age_s(nil, _now), do: nil
  defp age_s(at, now), do: DateTime.diff(now, utc(at), :second)

  # Schemaless reads of `timestamp` columns come back naive; they are UTC.
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp utc(%DateTime{} = at), do: at
  defp utc(nil), do: nil

  defp unreadable(part, e, fallback) do
    Logger.warning("server_activity: could not read #{part}: #{Exception.message(e)}")
    fallback
  end
end
