# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Reaction do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's unique indexes, kept by the store
  hosi_unique([:account_id, :note_id, :emoji], name: "reactions_account_id_note_id_emoji_index")

  schema "reactions" do
    field(:emoji, :string)
    belongs_to(:account, SukhiFedi.Schema.Account)
    belongs_to(:note, SukhiFedi.Schema.Note)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:emoji, :account_id, :note_id])
    |> validate_required([:emoji, :account_id, :note_id])
    |> unique_constraint([:account_id, :note_id, :emoji])
  end
end
