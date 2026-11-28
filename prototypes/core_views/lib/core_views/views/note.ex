# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CoreViews.Note do
  @moduledoc """
  A note. Compared with `SukhiFedi.Schema.Note`: `ap_id` is `ap/uri`, `account_id` is
  `ap/attributed-to`, and `note_media` and `note_tags` are many-valued facts of the note.
  """
  use Ecto.Schema
  use Ecto.Hosi.View
  import Ecto.Changeset

  hosi_where(type: "note")
  hosi_owner(:account_id)
  hosi_tuple(:account_id, :created_at)

  hosi_tombstone(
    keep: [:uuid, :api_id, :short_id, :ap_id, :account_id, :created_at],
    set: [type: "tombstone", former_type: "note"],
    mark: :deleted_at
  )

  hosi_keyword(:visibility, ["public", "unlisted", "followers", "direct"])

  schema "notes" do
    hosi_attributes(CoreViews.ActivityPub,
      type: :type,
      uuid: :uuid,
      api_id: :id,
      short_id: :short_id,
      former_type: :former_type,
      ap_id: :uri,
      account_id: :attributed_to,
      content: :content,
      tags: :tag,
      media_ids: :attachment,
      created_at: :registered_at,
      deleted_at: :deleted
    )

    field :visibility, :string, default: "public"
    field :domain, :string
    field :cw, :string
    field :sensitive, :boolean, default: false
    field :in_reply_to_ap_id, :string
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :uuid,
      :ap_id,
      :account_id,
      :content,
      :tags,
      :media_ids,
      :created_at,
      :visibility,
      :domain,
      :cw,
      :sensitive,
      :in_reply_to_ap_id
    ])
    |> put_created_at()
    |> validate_required([:account_id, :content])
    |> put_ids()
    |> unique_constraint(:ap_id, name: "notes_ap/uri_index")
  end

  # a remote note has a domain; its API ID is made from its URI
  defp put_ids(changeset) do
    case get_field(changeset, :domain) do
      nil ->
        CoreViews.Ids.put_ids(changeset, "on", nil)

      _ ->
        changeset = validate_required(changeset, [:ap_id])
        CoreViews.Ids.put_ids(changeset, "on", get_field(changeset, :ap_id))
    end
  end

  defp put_created_at(changeset) do
    case get_field(changeset, :created_at) do
      nil -> put_change(changeset, :created_at, DateTime.utc_now(:second))
      _ -> changeset
    end
  end
end

defmodule CoreViews.Tombstone do
  @moduledoc "What is left of a deleted record."
  use Ecto.Schema
  use Ecto.Hosi.View

  hosi_where(type: "tombstone")
  hosi_owner(:nobody)

  schema "tombstones" do
    hosi_attributes(CoreViews.ActivityPub,
      type: :type,
      uuid: :uuid,
      api_id: :id,
      short_id: :short_id,
      former_type: :former_type,
      ap_id: :uri,
      account_id: :attributed_to,
      deleted_at: :deleted
    )
  end
end
