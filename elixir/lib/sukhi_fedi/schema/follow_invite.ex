# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.FollowInvite do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  @moduledoc """
  A follow invite code (FEP-bebd) minted by a locked account's owner.
  A Follow presenting this code as its `instrument` is accepted without
  waiting in the approval queue.
  """

  # the catalog's unique indexes, kept by the store
  hosi_unique(:code)

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :cascade, name: "follow_invites_account_id_fkey")

  schema "follow_invites" do
    field(:account_id, :integer)
    field(:code, :string)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end
