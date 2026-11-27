# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.FollowRequest do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  @moduledoc """
  A pending inbound Follow held for a locked account's owner to approve.
  See the `add_follow_requests` migration for the field rationale.
  """

  # the catalog's unique indexes, kept by the store
  hosi_unique([:followee_id, :follower_uri],
    name: "follow_requests_followee_id_follower_uri_index"
  )

  schema "follow_requests" do
    field(:followee_id, :integer)
    field(:follower_uri, :string)
    field(:follow_activity, :map)
    field(:follower_inbox, :string)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end
