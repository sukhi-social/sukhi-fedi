# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Relay do
  use Ecto.Schema
  import Ecto.Changeset

  schema "relays" do
    field :actor_uri, :string
    field :inbox_uri, :string
    field :state, :string, default: "pending"
    # The local actor whose Follow opened this subscription, and that
    # Follow's activity id — both needed to build the matching Undo.
    field :follow_actor_uri, :string
    field :follow_activity_id, :string
    belongs_to :created_by, SukhiFedi.Schema.Account

    timestamps(type: :utc_datetime)
  end

  def changeset(relay, attrs) do
    relay
    |> cast(attrs, [
      :actor_uri,
      :inbox_uri,
      :state,
      :follow_actor_uri,
      :follow_activity_id,
      :created_by_id
    ])
    |> validate_required([:actor_uri, :inbox_uri])
    |> validate_inclusion(:state, ["pending", "accepted", "rejected"])
    |> unique_constraint(:actor_uri)
  end
end
