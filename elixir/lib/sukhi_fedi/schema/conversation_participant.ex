# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.ConversationParticipant do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's unique indexes, kept by the store
  hosi_unique([:conversation_ap_id, :account_id],
    name: "conversation_participants_conversation_ap_id_account_id_index"
  )

  schema "conversation_participants" do
    field(:conversation_ap_id, :string)
    field(:unread, :boolean, default: false)
    belongs_to(:account, SukhiFedi.Schema.Account)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(cp, attrs) do
    cp
    |> cast(attrs, [:conversation_ap_id, :account_id, :unread])
    |> validate_required([:conversation_ap_id, :account_id])
    |> unique_constraint([:conversation_ap_id, :account_id])
  end
end
