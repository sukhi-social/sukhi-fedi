# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Feeder do
  @moduledoc """
  The bridge from hosigraph to Oban's side. Delivery stays in PostgreSQL (sukhi's `outbox` table,
  its relay, Oban); this only carries each new line from hosigraph into that table.

  One round is one Postgres transaction: take the cursor's row (`FOR UPDATE`), read the lines after
  it from hosigraph (a read: nothing to undo), insert them into `outbox`, move the cursor. If the
  round dies anywhere, Postgres rolls back all of it and the next round starts at the same line, so
  a line enters `outbox` exactly once. (`source_id` is unique as a second guard.) Whether the
  remote receives it once is another matter: that is delivery, and it is at-least-once as today.

  Two feeders with the same name wait for one another on the cursor's row, so the lines are not
  taken twice.

  The source here is the outbox lines hosigraph holds (`Outbox.after_id`). If hosigraph could hand
  out its event log after a cursor, the lines would not need to exist and the source would be that
  log; the rest of this module would not change.

  Not decided: ids in the payload are hosigraph ids (the id mapping is open); and a line that is
  erased before a round takes it is never delivered, so a Delete has to be fed before its account's
  erase.
  """

  alias SukhiHosi.Outbox

  # sukhi's subjects (as the Ecto side names them)
  @subjects %{
    "Create" => {"sns.outbox.note.created", "note"},
    "Like" => {"sns.outbox.like.created", "reaction"},
    "Undo" => {"sns.outbox.like.undone", "reaction"},
    "Announce" => {"sns.outbox.announce.created", "boost"},
    "UndoAnnounce" => {"sns.outbox.announce.undone", "boost"},
    "Delete" => {"sns.outbox.note.deleted", "note"},
    "Add" => {"sns.outbox.add.created", "pinned_note"},
    "Remove" => {"sns.outbox.remove.created", "pinned_note"},
    "DeleteActor" => {"sns.outbox.actor.deleted", "account"}
  }

  @doc """
  One round for the feeder `name`. Returns the lines it took (`[]` when there are none).
  `opts`: `:limit`, and `:after_insert` (a function of the lines, run before the cursor moves).
  """
  def run_once(pg, db, name, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    {:ok, lines} =
      Postgrex.transaction(pg, fn conn ->
        Postgrex.query!(conn, "INSERT INTO hosi_feeder_cursor (name) VALUES ($1) ON CONFLICT DO NOTHING", [name])
        %{rows: [[at]]} = Postgrex.query!(conn, "SELECT at FROM hosi_feeder_cursor WHERE name = $1 FOR UPDATE", [name])

        case Outbox.after_id(db, at, limit) do
          [] ->
            []

          lines ->
            Enum.each(lines, &insert!(conn, &1))
            if f = opts[:after_insert], do: f.(lines)
            Postgrex.query!(conn, "UPDATE hosi_feeder_cursor SET at = $2 WHERE name = $1", [name, List.last(lines).id])
            lines
        end
      end)

    lines
  end

  # The payload as the delivery side reads it (sukhi's `Notes.Create` and `Interactions` build the same
  # keys): a Delete names the post by its IRI, which is all it can still be known by.
  defp payload("Delete", l), do: %{note_id: l.note, ap_id: l.ap_id, account_id: l.actor}
  defp payload(k, l) when k in ["Add", "Remove"], do: %{note_id: l.note, note_ap_id: l.ap_id, account_id: l.actor}
  defp payload("DeleteActor", l), do: %{account_id: l.actor, ap_id: l.ap_id}
  defp payload(_, l), do: %{note_id: l.note, account_id: l.actor}

  defp insert!(conn, %{id: id, kind: kind, note: note} = line) do
    {subject, type} = Map.fetch!(@subjects, kind)

    Postgrex.query!(
      conn,
      """
      INSERT INTO outbox (aggregate_type, aggregate_id, subject, payload, source_id)
      VALUES ($1, $2, $3, $4, $5) ON CONFLICT (source_id) DO NOTHING
      """,
      [type, to_string(note), subject, payload(kind, line), id]
    )
  end
end
