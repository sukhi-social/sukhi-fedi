# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.NoteMedia do
  @moduledoc """
  A media attachment of a note.

  Read and written by table name (`from(x in "note_media")`, `Repo.insert_all("note_media", ..)`);
  this module is what gives hosigraph the types of its columns. The row's own key is the
  entity id; the table's old composite key is by convention, not enforced.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "note_media" do
    field :note_id, :integer
    field :media_id, :integer
  end
end
