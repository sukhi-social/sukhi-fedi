# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.EmailCode do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  @moduledoc """
  A short-lived 6-digit code mailed to an address, for either verifying
  it (`purpose: "verify"`) or logging in with it (`purpose: "login"`).
  Only the SHA-256 hash of the code is stored. One live row per
  (account, purpose) — requesting again replaces it.
  """

  # the catalog's unique indexes, kept by the store
  hosi_unique([:account_id, :purpose], name: "email_codes_account_id_purpose_index")

  hosi_unique([:email, :purpose],
    name: "email_codes_signup_index",
    lower: [:email],
    where: [null: [:account_id]]
  )

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :cascade, name: "email_codes_account_id_fkey")

  schema "email_codes" do
    field(:email, :string)
    field(:purpose, :string)
    field(:code_hash, :string)
    field(:attempts, :integer, default: 0)
    field(:expires_at, :utc_datetime)

    belongs_to(:account, SukhiFedi.Schema.Account)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end
