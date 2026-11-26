# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Notification do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  alias SukhiFedi.Schema.{Account, Note}

  @types ~w(mention status reblog follow favourite follow_request poll update)

  # the catalog's unique indexes, kept by the store
  hosi_unique([:account_id, :from_account_id, :type, :note_id], name: "notifications_dedup_index")

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :cascade, name: "notifications_account_id_fkey")
  hosi_ref(:from_account_id, to: "accounts", on_delete: :cascade, name: "notifications_from_account_id_fkey")
  hosi_ref(:note_id, to: "notes", on_delete: :cascade, name: "notifications_note_id_fkey")

  schema "notifications" do
    field(:type, :string)
    field(:read_at, :utc_datetime)
    field(:dismissed_at, :utc_datetime)
    # Set only by `Notifications.list/2` when the viewer has grouping on:
    # every member's from_account (newest first), and the oldest member's id.
    field(:group, {:array, :any}, virtual: true)
    field(:cursor_id, :integer, virtual: true)
    belongs_to(:account, Account)
    belongs_to(:from_account, Account)
    belongs_to(:note, Note)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:account_id, :from_account_id, :note_id, :type, :read_at, :dismissed_at])
    |> validate_required([:account_id, :type])
    |> validate_inclusion(:type, @types)
    |> unique_constraint([:account_id, :from_account_id, :type, :note_id],
      name: :notifications_dedup_index
    )
  end

  def types, do: @types
end
