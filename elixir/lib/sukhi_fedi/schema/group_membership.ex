# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.GroupMembership do
  @moduledoc """
  A membership in a remote group: `pending` from the moment we send the
  `Join`, `accepted` once the group answers `Accept`. A `Reject` or a
  `Leave` deletes the row, so no row means "not a member".
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "group_memberships" do
    field :member_uri, :string
    field :group_id, :integer
    field :state, :string, default: "pending"

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:member_uri, :group_id, :state])
    |> validate_required([:member_uri, :group_id, :state])
    |> validate_inclusion(:state, ["pending", "accepted"])
    |> unique_constraint([:member_uri, :group_id])
  end
end
