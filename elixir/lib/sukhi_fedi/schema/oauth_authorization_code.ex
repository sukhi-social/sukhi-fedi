# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.OauthAuthorizationCode do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's unique indexes, kept by the store
  hosi_unique(:code_hash)

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :cascade, name: "oauth_authorization_codes_account_id_fkey")
  hosi_ref(:app_id, to: "oauth_apps", on_delete: :cascade, name: "oauth_authorization_codes_app_id_fkey")

  schema "oauth_authorization_codes" do
    field(:code_hash, :string)
    field(:redirect_uri, :string)
    field(:scopes, :string)
    field(:expires_at, :utc_datetime)
    field(:used_at, :utc_datetime)

    # PKCE (RFC 7636, S256 only): what the one who asked committed to. Set → the exchange needs the verifier.
    field(:code_challenge, :string)
    belongs_to(:app, SukhiFedi.Schema.OauthApp)
    belongs_to(:account, SukhiFedi.Schema.Account)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @required [:code_hash, :redirect_uri, :scopes, :expires_at, :app_id, :account_id]
  @optional [:used_at, :code_challenge]

  def changeset(code, attrs) do
    code
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:code_hash)
  end
end
