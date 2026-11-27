# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.OauthApp do
  use Ecto.Schema
  import Ecto.Changeset

  schema "oauth_apps" do
    field(:client_id, :string)
    field(:client_secret_hash, :string)
    field(:name, :string)
    field(:redirect_uri, :string)
    field(:scopes, :string, default: "read")
    field(:website, :string)
    belongs_to(:owner_account, SukhiFedi.Schema.Account)

    has_many(:access_tokens, SukhiFedi.Schema.OauthAccessToken, foreign_key: :app_id)
    has_many(:authorization_codes, SukhiFedi.Schema.OauthAuthorizationCode, foreign_key: :app_id)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @required [:client_id, :client_secret_hash, :name, :redirect_uri, :scopes]
  @optional [:website, :owner_account_id]

  def changeset(app, attrs) do
    app
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:client_id)
  end
end
