# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.RebuildRemoteNotes do
  @moduledoc """
  One-off: rebuild remote notes that still carry a pre-snowflake,
  sequential `id`.

  Those rows predate the snowflake-id migration, so they sort as ancient
  in id-ordered timelines, and (until v0.2.2) their `created_at` was the
  fetch time rather than the origin `published`. This re-fetches each
  one, mints a fresh snowflake id, and stamps `created_at` from the
  remote `published`.

  Because the id is the primary key, every row that points at the old id
  must move with it. We don't hardcode that list — we read it from the
  catalog (`note_fk_refs/0`), so a table added later can't be silently
  missed and have its reactions/boosts cascade-deleted.

  Per note, in one transaction:

    1. insert a new row (snowflake id, `ap_id` left NULL for now so the
       unique index doesn't collide with the row we're replacing),
       keeping every stored field and setting `created_at` from the
       re-fetched `published`;
    2. repoint each FK ref from the old id to the new id;
    3. delete the old row (now unreferenced — nothing cascades);
    4. move the real `ap_id` onto the new row.

  Fetch-first: a note whose origin is gone or unreachable is left exactly
  as-is, never deleted. Reply threading survives because it keys on
  `ap_id` (preserved), not the numeric id. Idempotent: a second run finds
  no sequential ids left.

  Run on the gateway (it owns the Repo and the federation fetch path):

      bin/sukhi_fedi eval 'SukhiFedi.Maintenance.RebuildRemoteNotes.run(:dry_run)'
      bin/sukhi_fedi eval 'SukhiFedi.Maintenance.RebuildRemoteNotes.run(:execute)'
  """

  import Ecto.Query
  require Logger

  alias SukhiFedi.AP.Published
  alias SukhiFedi.Federation.FedifyClient
  alias SukhiFedi.Maintenance.Progress
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Note

  # Snowflake ids are `((ms_since_2024) << 16) | seq` — comfortably above
  # 1e15 for any real timestamp. Pre-migration serial ids are tiny, so
  # this threshold separates them with a wide margin.
  @seq_threshold 1_000_000_000_000

  @spec run(:dry_run | :execute) :: map()
  def run(mode \\ :dry_run) do
    targets = target_notes()
    refs = note_fk_refs()

    Logger.info(
      "rebuild_remote_notes: mode=#{mode}, candidates=#{length(targets)}, " <>
        "fk_refs=#{inspect(refs)}"
    )

    case mode do
      :dry_run ->
        for n <- targets, do: Logger.info("  would rebuild ##{n.id} #{n.ap_id}")
        %{mode: :dry_run, candidates: length(targets), fk_refs: refs}

      :execute ->
        summary =
          Progress.track("rebuild_remote_notes", mode, length(targets), "rebuilding", fn run ->
            {results, run} = Progress.map(run, targets, &process/1)
            {tally(results), run}
          end)

        Logger.info("rebuild_remote_notes done: #{inspect(summary)}")
        Map.merge(summary, %{mode: :execute, fk_refs: refs})
    end
  end

  @doc "Remote notes whose id is still a pre-snowflake serial."
  def target_notes do
    from(n in Note,
      # `domain`, not `ap_id`: local notes now carry an ap_id too, and the
      # old local ones have small serial ids that would wrongly match here.
      where: not is_nil(n.domain) and n.id < ^@seq_threshold,
      order_by: n.id
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

  defp process(%Note{} = old) do
    case fetch(old.ap_id) do
      {:ok, json} ->
        case rebuild(old, json, note_fk_refs()) do
          {:ok, {old_id, new_id}} ->
            Logger.info("  rebuilt ##{old_id} -> ##{new_id}")
            :rebuilt

          {:error, reason} ->
            Logger.error("  failed ##{old.id} (#{old.ap_id}): #{inspect(reason)}")
            :error
        end

      {:error, reason} ->
        Logger.warning("  skip ##{old.id} (#{old.ap_id}): fetch failed #{inspect(reason)}")
        :skipped
    end
  end

  defp fetch(uri) do
    case FedifyClient.fetch(uri, SukhiFedi.Accounts.signing_identity()) do
      {:ok, %{"document" => doc}} when is_map(doc) -> {:ok, doc}
      {:ok, other} -> {:error, {:unexpected_fetch_result, other}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Swap one note for a snowflake-id copy, carrying every FK ref across.
  Exposed for testing; `refs` is the `note_fk_refs/0` list.
  """
  def rebuild(%Note{} = old, json, refs) do
    created_at = Published.at(json) || old.created_at

    Repo.transaction(fn ->
      new =
        %Note{}
        |> Ecto.Changeset.change(%{
          account_id: old.account_id,
          content: old.content,
          visibility: old.visibility,
          cw: old.cw,
          in_reply_to_ap_id: old.in_reply_to_ap_id,
          quote_of_ap_id: old.quote_of_ap_id,
          conversation_ap_id: old.conversation_ap_id,
          mfm: old.mfm,
          # Carry the Article title, NSFW flag and custom emoji across too —
          # they're real, user-visible columns and dropping them on a re-mint
          # loses them (the title in particular for hackers.pub long-form posts).
          title: old.title,
          sensitive: old.sensitive,
          emojis: old.emojis,
          created_at: created_at,
          # carry locality over (this is a remote note); change/2 skips the
          # changeset's domain-from-ap_id derivation, so set it explicitly.
          domain: old.domain,
          # NULL for now: the real ap_id still lives on `old` and the
          # column is uniquely indexed. We move it over after the delete.
          ap_id: nil
        })
        |> Repo.insert!()

      Enum.each(refs, fn {table, column} ->
        Repo.query!(
          "UPDATE #{quote_ident(table)} SET #{quote_ident(column)} = $1 WHERE #{quote_ident(column)} = $2",
          [new.id, old.id]
        )
      end)

      Repo.delete!(old)
      Repo.query!("UPDATE notes SET ap_id = $1 WHERE id = $2", [old.ap_id, new.id])

      {old.id, new.id}
    end)
  end

  # Table/column names come from the catalog, not user input, but quote
  # them anyway so an unusual identifier can't break the statement.
  defp quote_ident(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")

  defp tally(results) do
    %{
      rebuilt: Enum.count(results, &(&1 == :rebuilt)),
      skipped: Enum.count(results, &(&1 == :skipped)),
      errors: Enum.count(results, &(&1 == :error))
    }
  end
end
