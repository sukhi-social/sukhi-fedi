# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.FollowRequest do
  use Ecto.Schema

  @moduledoc """
  A pending inbound Follow held for a locked account's owner to approve.
  See the `add_follow_requests` migration for the field rationale.
  """

  schema "follow_requests" do
    field :followee_id, :integer
    field :follower_uri, :string
    field :follow_activity, :map
    field :follower_inbox, :string

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end
