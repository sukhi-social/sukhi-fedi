# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Metrics do
  @moduledoc """
  The history store for host-resource metrics — owns the `metric_samples`
  table: writing snapshots, reading windows back, and pruning old rows.

  Live readings come from `SukhiFedi.SystemMetrics` (the single os_mon
  home). This module's job is *time*: it folds one snapshot into a flat
  row (`record/0`, called on a timer by `SukhiFedi.Metrics.Sampler`),
  hands windows of rows back as plain maps (`history/1`, served by
  `SukhiFedi.Web.MetricsController` for offline analysis), and trims the
  tail (`prune/1`).

  Narrow on purpose: only the ephemeral host figures live here. Account
  and status growth is already timestamped in the DB, so it is not
  duplicated — reconstruct those curves from `notes`/`accounts` instead.
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.SystemMetrics
  alias SukhiFedi.Schema.MetricSample

  @doc """
  Sample `SystemMetrics` once and persist it as a row. Returns the
  inserted `MetricSample`.
  """
  @spec record() :: struct()
  def record do
    SystemMetrics.snapshot()
    |> to_row()
    |> Map.put(:outbox_dlq_depth, dlq_depth())
    |> then(&struct(MetricSample, &1))
    |> Repo.insert!()
  end

  @doc """
  How many jobs have given up — Oban rows in `discarded`. `oban_jobs` is
  one shared table, so this counts both sides: the delivery node
  (`Outbox.DispatchWorker`, `Delivery.Worker` — an activity that never
  reached anyone's inbox) and the gateway's own queues. Federation is
  what normally lands here, which is why the sampler words its warning
  that way. (This used to be the depth of the `OUTBOX_DLQ` JetStream
  stream; the dead-letter shelf moved into Oban with the outbox relay.)

  `nil` when the count can't be taken — `oban_jobs` is the delivery app's
  table and the DB is shared, so on a gateway whose delivery migrations
  haven't run there is nothing to count. A standing non-zero value means
  federation delivery is failing for someone: the sampler logs a warning
  and it rides the history series.
  """
  @spec dlq_depth() :: non_neg_integer() | nil
  def dlq_depth do
    case Repo.query("SELECT count(*) FROM oban_jobs WHERE state = 'discarded'", []) do
      {:ok, %{rows: [[n]]}} when is_integer(n) -> n
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Rows in `[since, until]`, oldest first, as JSON-friendly maps.

  Options:

    * `:since` / `:until` — `DateTime` bounds (defaults: 24h ago / now)
    * `:limit` — max rows (default 5_000, hard-capped at 50_000) so one
      request can never try to stream the whole table into memory
  """
  @spec history(keyword()) :: [map()]
  def history(opts \\ []) do
    now = DateTime.utc_now()
    since = Keyword.get(opts, :since, DateTime.add(now, -86_400, :second))
    until = Keyword.get(opts, :until, now)
    limit = opts |> Keyword.get(:limit, 5_000) |> min(50_000) |> max(1)

    from(s in MetricSample,
      where: s.sampled_at >= ^since and s.sampled_at <= ^until,
      order_by: [asc: s.sampled_at],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  @doc "Delete rows older than `retention_days`. Returns the count deleted."
  @spec prune(pos_integer()) :: non_neg_integer()
  def prune(retention_days) when is_integer(retention_days) and retention_days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86_400, :second)
    {deleted, _} = Repo.delete_all(from(s in MetricSample, where: s.sampled_at < ^cutoff))
    deleted
  end

  # ── snapshot → row ─────────────────────────────────────────────────────────

  # Fold a SystemMetrics snapshot into flat columns. Disk is a list of
  # mounts; we keep the largest one (by capacity) as "the disk" — on a
  # single-volume box that's root, and it's the one capacity planning
  # cares about. Empty list (before disksup's first scan) → nils.
  defp to_row(snap) do
    primary_disk =
      snap.disk
      |> Enum.max_by(& &1.total, fn -> nil end)

    %{
      sampled_at: DateTime.utc_now(),
      cpu_percent: snap.cpu,
      load1: snap.load["1m"],
      load5: snap.load["5m"],
      load15: snap.load["15m"],
      mem_total: snap.memory.total,
      mem_used: snap.memory.used,
      mem_available: snap.memory.available,
      swap_total: snap.memory.swap_total,
      swap_free: snap.memory.swap_free,
      beam_total: snap.beam.total,
      beam_processes: snap.beam.processes,
      beam_binary: snap.beam.binary,
      disk_total: primary_disk && primary_disk.total,
      disk_used_percent: primary_disk && primary_disk.used_percent * 1.0
    }
  end

  @fields ~w(sampled_at cpu_percent load1 load5 load15 mem_total mem_used
             mem_available swap_total swap_free beam_total beam_processes
             beam_binary disk_total disk_used_percent outbox_dlq_depth)a

  defp to_map(%MetricSample{} = s), do: Map.take(s, @fields)
end
