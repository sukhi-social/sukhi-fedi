# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.NoteTag do
  @moduledoc """
  A hashtag of a note.

  Read and written by table name (`from(x in "note_tags")`, `Repo.insert_all("note_tags", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's unique indexes, kept by the store
  hosi_unique([:note_id, :tag_id], name: "note_tags_note_id_tag_id_index")

  @primary_key {:id, :id, autogenerate: true}
  schema "note_tags" do
    field(:note_id, :integer)
    field(:tag_id, :integer)
  end
end
