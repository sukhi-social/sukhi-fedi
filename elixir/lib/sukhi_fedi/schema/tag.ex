# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Tag do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's unique indexes, kept by the store
  hosi_unique(:name)

  schema "tags" do
    field(:name, :string)

    many_to_many(:notes, SukhiFedi.Schema.Note, join_through: "note_tags")

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:name)
  end
end
