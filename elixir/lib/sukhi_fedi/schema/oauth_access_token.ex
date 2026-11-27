# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.OauthAccessToken do
  use Ecto.Schema
  import Ecto.Changeset

  schema "oauth_access_tokens" do
    field(:token_hash, :string)
    field(:refresh_token_hash, :string)
    field(:scopes, :string)
    field(:expires_at, :utc_datetime)
    field(:revoked_at, :utc_datetime)
    field(:last_used_at, :utc_datetime)
    belongs_to(:app, SukhiFedi.Schema.OauthApp)
    # nullable for client_credentials grant (no end-user identity)
    belongs_to(:account, SukhiFedi.Schema.Account)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @required [:token_hash, :scopes, :app_id]
  @optional [:refresh_token_hash, :expires_at, :revoked_at, :last_used_at, :account_id]

  def changeset(token, attrs) do
    token
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:token_hash)
    |> unique_constraint(:refresh_token_hash)
  end
end
