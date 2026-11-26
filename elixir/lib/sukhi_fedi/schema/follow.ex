# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Follow do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's unique indexes, kept by the store
  hosi_unique([:follower_uri, :followee_id], name: "follows_follower_uri_followee_id_index")

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:followee_id, to: "accounts", on_delete: :none, name: "follows_followee_id_fkey")

  schema "follows" do
    field(:follower_uri, :string)
    field(:followee_id, :integer)
    field(:state, :string, default: "pending")

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end
