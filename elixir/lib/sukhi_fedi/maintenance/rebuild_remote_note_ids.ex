# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.RebuildRemoteNoteIds do
  @moduledoc """
  One-off: re-mint a remote note's snowflake `id` from its `created_at`,
  so id-ordered timelines sort by *when it was authored*, not when we
  happened to receive it.

  A snowflake `id` is `((ms_since_2024) << 16) | seq`, minted by the DB
  default `snowflake_id()` at **insert time**. `created_at`, since v0.2.2,
  carries the origin `published`. For a live post the two are within
  seconds, so they agree. But a back-filled thread or a delayed delivery
  is inserted *now* while it was published hours or days ago — it gets a
  fresh id and jumps to the top of the timeline, showing an old date in a
  new position. Timelines order by `desc: id` (`SukhiFedi.Timelines`), so
  the displayed time and the slot disagree.

  This re-mints the id from `created_at` (second precision, matching
  `snowflake_id()`'s epoch and layout), so id-order == created_at-order.
  It does **not** touch `created_at` itself — that must already be the
  true `published`. The raw inbound bytes in rustfs are the system of
  record for that; run `RebuildFromArchive` first if any note still shows
  a fetch-time date, then run this to align the id to it.

  Because the id is the primary key, every row that points at the old id
  must move with it. We read the FK list from the catalog
  (`note_fk_refs/0`) so a table added later can't be silently missed and
  have its reactions/boosts cascade-deleted. Per note, in one
  transaction:

    1. insert a copy with the new id (`ap_id` left NULL so the unique
       index doesn't collide with the row we're replacing), every other
       field carried verbatim;
    2. repoint each FK ref from the old id to the new id;
    3. delete the old row (now unreferenced — nothing cascades);
    4. move the real `ap_id` onto the new row.

  Idempotent: a note whose id already encodes its `created_at` (within
  `skew_s`) is skipped, so a second run is a no-op. Local notes (no
  `ap_id`) are never touched — their id and created_at are minted
  together at post time and already agree.

  Run on the gateway (it owns the Repo):

      bin/sukhi_fedi eval 'SukhiFedi.Maintenance.RebuildRemoteNoteIds.run(:dry_run)'
      bin/sukhi_fedi eval 'SukhiFedi.Maintenance.RebuildRemoteNoteIds.run(:execute)'
  """

  import Ecto.Query
  require Logger

  alias SukhiFedi.Maintenance.Progress
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Note

  # Matches the `snowflake_id()` migration: epoch 2024-01-01, 16-bit seq.
  @epoch_ms 1_704_067_200_000
  @seq_threshold 1_000_000_000_000

  # Default drift tolerance. Live posts land well under a minute of their
  # `published`; only genuine back-fills exceed this, so we leave the
  # already-fine rows (and their ids) alone.
  @default_skew_s 300

  @spec run(:dry_run | :execute, non_neg_integer()) :: map()
  def run(mode \\ :dry_run, skew_s \\ @default_skew_s) do
    targets = target_notes(skew_s)
    refs = note_fk_refs()

    Logger.info(
      "rebuild_remote_note_ids: mode=#{mode}, skew_s=#{skew_s}, " <>
        "candidates=#{length(targets)}, fk_refs=#{inspect(refs)}"
    )

    case mode do
      :dry_run ->
        for n <- targets,
            do: Logger.info("  would remint ##{n.id} #{n.ap_id} -> id@#{n.created_at}")

        %{mode: :dry_run, candidates: length(targets), fk_refs: refs}

      :execute ->
        summary =
          Progress.track("rebuild_remote_note_ids", mode, length(targets), "reminting", fn run ->
            {results, run} = Progress.map(run, targets, &process(&1, refs))
            {tally(results), run}
          end)

        Logger.info("rebuild_remote_note_ids done: #{inspect(summary)}")
        Map.merge(summary, %{mode: :execute, fk_refs: refs})
    end
  end

  @doc """
  Remote snowflake-range notes whose id-encoded time drifts from
  `created_at` by more than `skew_s` seconds.
  """
  def target_notes(skew_s \\ @default_skew_s) do
    from(n in Note,
      where: not is_nil(n.domain) and n.id > ^@seq_threshold,
      where:
        fragment(
          "abs(extract(epoch from (to_timestamp(((? >> 16) + ?) / 1000.0) - (? at time zone 'UTC')))) > ?",
          n.id,
          ^@epoch_ms,
          n.created_at,
          ^skew_s
        ),
      order_by: n.created_at
    )
    |> Repo.all()
  end

  @doc "Every `(table, column)` whose FOREIGN KEY points at `notes(id)`."
  def note_fk_refs do
    sql = """
    SELECT tc.table_name, kcu.column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
     AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage ccu
      ON tc.constraint_name = ccu.constraint_name
     AND tc.table_schema = ccu.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND ccu.table_name = 'notes'
      AND ccu.column_name = 'id'
    """

    Repo.query!(sql).rows
    |> Enum.map(fn [table, column] -> {table, column} end)
  end

  defp process(%Note{} = old, refs) do
    case rebuild(old, refs) do
      {:ok, {old_id, new_id}} ->
        Logger.info("  reminted ##{old_id} -> ##{new_id}")
        :reminted

      {:error, reason} ->
        Logger.error("  failed ##{old.id} (#{old.ap_id}): #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Swap one note for a copy whose snowflake id encodes its `created_at`,
  carrying every FK ref across. Exposed for testing; `refs` is the
  `note_fk_refs/0` list.
  """
  def rebuild(%Note{} = old, refs) do
    Repo.transaction(fn ->
      new_id = mint_id_from_created_at(old.id)

      Repo.query!(
        """
        INSERT INTO notes
          (id, account_id, content, visibility, ap_id, created_at, cw,
           in_reply_to_ap_id, conversation_ap_id, quote_of_ap_id, mfm, emojis,
           domain, title, sensitive)
        SELECT $1, account_id, content, visibility, NULL, created_at, cw,
           in_reply_to_ap_id, conversation_ap_id, quote_of_ap_id, mfm, emojis,
           domain, title, sensitive
        FROM notes WHERE id = $2
        """,
        [new_id, old.id]
      )

      Enum.each(refs, fn {table, column} ->
        Repo.query!(
          "UPDATE #{quote_ident(table)} SET #{quote_ident(column)} = $1 WHERE #{quote_ident(column)} = $2",
          [new_id, old.id]
        )
      end)

      Repo.query!("DELETE FROM notes WHERE id = $1", [old.id])
      Repo.query!("UPDATE notes SET ap_id = $1 WHERE id = $2", [old.ap_id, new_id])

      {old.id, new_id}
    end)
  end

  # Mint the id in SQL so it shares `snowflake_id()`'s exact arithmetic
  # and the same `snowflake_seq` (the low 16 bits stay globally unique).
  defp mint_id_from_created_at(old_id) do
    %{rows: [[new_id]]} =
      Repo.query!(
        """
        SELECT ((floor(extract(epoch from (created_at at time zone 'UTC')) * 1000)::bigint - $1) << 16)
               | (nextval('snowflake_seq') % 65536)
        FROM notes WHERE id = $2
        """,
        [@epoch_ms, old_id]
      )

    new_id
  end

  # Table/column names come from the catalog, not user input, but quote
  # them anyway so an unusual identifier can't break the statement.
  defp quote_ident(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")

  defp tally(results) do
    %{
      reminted: Enum.count(results, &(&1 == :reminted)),
      errors: Enum.count(results, &(&1 == :error))
    }
  end
end
