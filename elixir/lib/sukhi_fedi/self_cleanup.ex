# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.SelfCleanup do
  @moduledoc """
  Self-cleanup of one's own old posts — hard-delete locally, federate the
  Delete.

  For each targeted note: delete the row (media cascade too), append a
  `note_cleanup_ledger` row (the "生成と削除のDB" keeping its birth and
  deletion timestamp), and enqueue the **same** `Delete(Note)` a manual delete
  sends so remote peers forget it. The delete + ledger + Delete share one
  `Ecto.Multi` per note (`Notes.Create.delete_note_for_cleanup/3`), so the
  federated Delete can't be lost (the irreversible-loss discipline).

  Scope is **one account's local notes** (`is_nil(domain)`), and the protected
  set is excluded so cleanup never reaches for something the owner is still
  leaning on:

    * **pinned** — a note in `pinned_notes` (the featured profile shelf).
    * **direct (DMs)** — `visibility == "direct"`; conversations aren't posts
      to tidy.

  `run/3` mirrors `Maintenance.WipeRemote`'s dry-run honesty: `:dry_run` counts
  what *would* be deleted and what is protected, touching nothing; `:execute`
  enqueues the deletion in `@batch`-sized Oban jobs (small-box budget). Opts:

    * `:older_than_days` — only notes older than N days (default #{0}, i.e. all).
    * `:reason` — recorded on each ledger row.
  """

  import Ecto.Query
  require Logger

  alias SukhiFedi.{Notes, Repo}
  alias SukhiFedi.SelfCleanup.Worker

  # The named Oban instance (the app supervises it as `SukhiFedi.Oban`, not the
  # default `Oban`), matching how ScheduledStatuses enqueues.
  @oban SukhiFedi.Oban

  # How many notes one Oban job archives. Each archival is its own small
  # transaction inside the job; the batch just bounds how many a single job
  # holds, so a 768MB box never loads a whole history at once.
  @batch 50

  @spec run(integer(), :dry_run | :execute, keyword()) :: map()
  def run(account_id, mode \\ :dry_run, opts \\ []) when is_integer(account_id) do
    reason = opts[:reason]
    older_than_days = opts[:older_than_days] || 0

    target = target_scope(account_id, older_than_days)
    affected = Repo.aggregate(target, :count, :id)
    protected = protected_breakdown(account_id, older_than_days)

    Logger.info(
      "self_cleanup: account=#{account_id}, mode=#{mode}, " <>
        "older_than_days=#{older_than_days}, affected=#{affected}, " <>
        "protected=#{inspect(protected)}"
    )

    case mode do
      :dry_run ->
        %{
          mode: :dry_run,
          account_id: account_id,
          older_than_days: older_than_days,
          affected: affected,
          protected: protected
        }

      :execute ->
        enqueued = enqueue_batches(account_id, older_than_days, reason)

        %{
          mode: :execute,
          account_id: account_id,
          older_than_days: older_than_days,
          affected: affected,
          protected: protected,
          enqueued_jobs: enqueued
        }
    end
  end

  @doc """
  The ids one Oban batch deletes, oldest first. Reads the live scope each
  time (not a frozen snapshot) so a note pinned since the job was enqueued
  naturally drops out. Notes already recorded in the ledger are excluded for
  idempotency — a retried job won't re-process what a previous run finished.
  Capped at `@batch`.
  """
  @spec next_batch(integer(), integer()) :: [integer()]
  def next_batch(account_id, older_than_days) do
    target_scope(account_id, older_than_days)
    |> order_by([n], asc: n.id)
    |> limit(@batch)
    |> select([n], n.id)
    |> Repo.all()
  end

  # The notes a cleanup would touch: this account's *local* notes, not already
  # in the ledger (already deleted), older than the cutoff, minus the
  # protected set (pinned, DMs). Since the note row is gone after deletion, a
  # re-run naturally finds nothing — the ledger exclusion is a belt-and-
  # suspenders guard for the window between ledger insert and note delete (in
  # case of a partial failure that still committed the ledger row).
  defp target_scope(account_id, older_than_days) do
    Notes.local_notes()
    |> where([n], n.account_id == ^account_id)
    |> where([n], n.visibility in ^SukhiFedi.Visibility.not_direct())
    |> exclude_pinned()
    |> exclude_ledger()
    |> older_than(older_than_days)
  end

  defp exclude_pinned(query) do
    from(n in query,
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM pinned_notes p WHERE p.note_id = ?)",
          n.id
        )
    )
  end

  defp exclude_ledger(query) do
    from(n in query,
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM note_cleanup_ledger l WHERE l.note_id = ?)",
          n.id
        )
    )
  end

  defp older_than(query, days) when days > 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)
    from(n in query, where: n.created_at < ^cutoff)
  end

  defp older_than(query, _days), do: query

  # An honest accounting of what's held back, for the dry-run preview. Counted
  # over the same account + cutoff so the numbers add up with `affected`.
  defp protected_breakdown(account_id, older_than_days) do
    base =
      Notes.local_notes()
      |> where([n], n.account_id == ^account_id)
      |> exclude_ledger()
      |> older_than(older_than_days)

    pinned =
      from(n in base,
        where:
          fragment("EXISTS (SELECT 1 FROM pinned_notes p WHERE p.note_id = ?)", n.id)
      )
      |> Repo.aggregate(:count, :id)

    direct =
      from(n in base, where: n.visibility == "direct")
      |> Repo.aggregate(:count, :id)

    %{pinned: pinned, direct: direct}
  end

  # One Oban job per `@batch` ids. Counting `affected` already gave us the
  # total; ceil-divide to know how many jobs cover it. Each job re-reads the
  # live scope, so even if rows shift between count and run the work converges.
  defp enqueue_batches(account_id, older_than_days, reason) do
    affected =
      target_scope(account_id, older_than_days)
      |> Repo.aggregate(:count, :id)

    jobs = ceil_div(affected, @batch)

    Enum.each(1..max(jobs, 0)//1, fn _ ->
      %{account_id: account_id, older_than_days: older_than_days, reason: reason}
      |> Worker.new()
      |> then(&Oban.insert!(@oban, &1))
    end)

    jobs
  end

  defp ceil_div(total, _per) when total <= 0, do: 0
  defp ceil_div(total, per), do: div(total + per - 1, per)
end
