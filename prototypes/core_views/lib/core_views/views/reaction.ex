# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.Reaction do
  @moduledoc "A `Like` with an emoji. `account_id` is `ap/actor`, `note_id` is `ap/object`."
  use Ecto.Schema
  use Ecto.Hosi.View
  import Ecto.Changeset

  hosi_where(type: "like")
  hosi_owner(:account_id)

  hosi_unique([:account_id, :note_id, :emoji],
    name: "reactions_account_id_note_id_emoji_index",
    where: [eq: [type: "like"]]
  )

  schema "reactions" do
    hosi_attributes(CoreViews.ActivityPub,
      type: :type,
      uuid: :uuid,
      api_id: :id,
      short_id: :short_id,
      ap_id: :uri,
      account_id: :actor,
      note_id: :object,
      emoji: :content,
      created_at: :registered_at
    )

    # set for a record from another server: its API ID is then made from `ap_id`
    field :remote, :boolean, virtual: true, default: false
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:uuid, :ap_id, :remote, :account_id, :note_id, :emoji, :created_at])
    |> put_created_at()
    |> CoreViews.Ids.put_ids_of_activity("xl")
    |> validate_required([:account_id, :note_id, :emoji])
    |> unique_constraint([:account_id, :note_id, :emoji],
      name: "reactions_account_id_note_id_emoji_index"
    )
  end

  defp put_created_at(changeset) do
    case get_field(changeset, :created_at) do
      nil -> put_change(changeset, :created_at, DateTime.utc_now(:second))
      _ -> changeset
    end
  end
end
