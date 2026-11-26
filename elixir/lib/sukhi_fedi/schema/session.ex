# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Session do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's unique indexes, kept by the store
  hosi_unique(:token_hash)

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :cascade, name: "sessions_account_id_fkey")

  schema "sessions" do
    field(:token_hash, :string)
    field(:expires_at, :utc_datetime)
    # Coarse device fingerprint, captured at mint (nullable: old rows
    # and any non-request mint have none). Feeds the security page's
    # session list and the new-device email.
    field(:ip_text, :string)
    field(:user_agent, :string)
    field(:last_seen_at, :utc_datetime)
    belongs_to(:account, SukhiFedi.Schema.Account)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end
