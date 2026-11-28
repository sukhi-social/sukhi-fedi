# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.Follow do
  @moduledoc """
  A `Follow`. `followee_id` is `ap/object`.

  New here: `follower_id` (`ap/actor`), the follower's account id. The owner of a follow is its
  maker (D13), and an owner is an id; `SukhiFedi.Schema.Follow` has only `follower_uri`.
  """
  use Ecto.Schema
  use Ecto.Hosi.View
  import Ecto.Changeset

  hosi_where(type: "follow")
  hosi_owner(:follower_id)

  hosi_unique([:follower_uri, :followee_id],
    name: "follows_follower_uri_followee_id_index",
    where: [eq: [type: "follow"]]
  )

  hosi_keyword(:state, ["pending", "accepted"])

  schema "follows" do
    hosi_attributes(CoreViews.ActivityPub,
      type: :type,
      uuid: :uuid,
      api_id: :id,
      short_id: :short_id,
      ap_id: :uri,
      follower_id: :actor,
      followee_id: :object,
      created_at: :registered_at
    )

    field :follower_uri, :string, source: :"follow/actor-uri"
    field :state, :string, default: "pending", source: :"follow/state"

    # set for a record from another server: its API ID is then made from `ap_id`
    field :remote, :boolean, virtual: true, default: false
  end

  def changeset(follow, attrs) do
    follow
    |> cast(attrs, [
      :uuid,
      :ap_id,
      :remote,
      :follower_id,
      :follower_uri,
      :followee_id,
      :state,
      :created_at
    ])
    |> put_created_at()
    |> CoreViews.Ids.put_ids_of_activity("xf")
    |> validate_required([:follower_uri, :followee_id])
    |> unique_constraint([:follower_uri, :followee_id],
      name: "follows_follower_uri_followee_id_index"
    )
  end

  defp put_created_at(changeset) do
    case get_field(changeset, :created_at) do
      nil -> put_change(changeset, :created_at, DateTime.utc_now(:second))
      _ -> changeset
    end
  end
end
