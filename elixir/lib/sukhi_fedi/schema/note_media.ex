# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.NoteMedia do
  @moduledoc """
  A media attachment of a note.

  Read and written by table name (`from(x in "note_media")`, `Repo.insert_all("note_media", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's unique indexes, kept by the store
  hosi_unique([:note_id, :media_id], name: "note_media_note_id_media_id_index")

  @primary_key {:id, :id, autogenerate: true}
  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:media_id, to: "media", on_delete: :cascade, name: "note_media_media_id_fkey")
  hosi_ref(:note_id, to: "notes", on_delete: :cascade, name: "note_media_note_id_fkey")

  schema "note_media" do
    field(:note_id, :integer)
    field(:media_id, :integer)
  end
end
