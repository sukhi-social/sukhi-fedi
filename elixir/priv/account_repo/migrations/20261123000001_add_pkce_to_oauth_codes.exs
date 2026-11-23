# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountRepo.Migrations.AddPkceToOauthCodes do
  @moduledoc false
  # PKCE (RFC 7636): the challenge an authorization code was asked with.
  # Null for the codes of clients that hold a secret and did not use PKCE.
  use Ecto.Migration

  def change do
    alter table(:oauth_authorization_codes) do
      add :code_challenge, :text
    end
  end
end
