# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PushSubscription do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's unique indexes, kept by the store
  hosi_unique(:endpoint)

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :cascade, name: "push_subscriptions_account_id_fkey")

  schema "push_subscriptions" do
    belongs_to(:account, SukhiFedi.Schema.Account)
    field(:endpoint, :string)
    field(:p256dh_key, :string)
    field(:auth_key, :string)
    field(:alerts, :map)
    timestamps()
  end
end
