# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Boost do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the newest rows of some authors: Repo.highest_in/5, for timelines
  hosi_tuple(:account_id, :created_at)

  # the catalog's unique indexes, kept by the store
  # kept as hosigraph's own tuple (both fields are always set), not a derived JSON text
  hosi_unique([:account_id, :note_id], name: "boosts_account_id_note_id_index", tuple: true)

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:note_id, to: "notes", on_delete: :cascade, name: "boosts_note_id_fkey")

  schema "boosts" do
    belongs_to(:account, SukhiFedi.Schema.Account)
    belongs_to(:note, SukhiFedi.Schema.Note)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(boost, attrs) do
    boost
    |> cast(attrs, [:account_id, :note_id])
    |> validate_required([:account_id, :note_id])
    |> unique_constraint([:account_id, :note_id])
  end
end
