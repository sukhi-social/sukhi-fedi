# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.Boost do
  @moduledoc "An `Announce`. `account_id` is `ap/actor`, `note_id` is `ap/object`."
  use Ecto.Schema
  use Ecto.Hosi.View
  import Ecto.Changeset

  hosi_where(type: "announce")
  hosi_owner(:account_id)
  hosi_tuple(:account_id, :created_at)

  # one per actor and note. `ap/actor` + `ap/object` are shared with reactions, so the rule says
  # which records it is about; that makes it a rule the adapter keeps, not a hosigraph tuple.
  hosi_unique([:account_id, :note_id],
    name: "boosts_account_id_note_id_index",
    where: [eq: [type: "announce"]]
  )

  schema "boosts" do
    hosi_attributes(CoreViews.ActivityPub,
      type: :type,
      uuid: :uuid,
      api_id: :id,
      short_id: :short_id,
      ap_id: :uri,
      account_id: :actor,
      note_id: :object
    )

    # Its own attribute, not `ap/registered-at`: the (actor, time) index holds every record that
    # has both, so reactions would sit in it and be read past one by one.
    field :created_at, :utc_datetime, source: :"announce/at"

    # set for a record from another server: its API ID is then made from `ap_id`
    field :remote, :boolean, virtual: true, default: false
  end

  def changeset(boost, attrs) do
    boost
    |> cast(attrs, [:uuid, :ap_id, :remote, :account_id, :note_id, :created_at])
    |> put_created_at()
    |> CoreViews.Ids.put_ids_of_activity("xa")
    |> validate_required([:account_id, :note_id])
    |> unique_constraint([:account_id, :note_id], name: "boosts_account_id_note_id_index")
  end

  defp put_created_at(changeset) do
    case get_field(changeset, :created_at) do
      nil -> put_change(changeset, :created_at, DateTime.utc_now(:second))
      _ -> changeset
    end
  end
end
