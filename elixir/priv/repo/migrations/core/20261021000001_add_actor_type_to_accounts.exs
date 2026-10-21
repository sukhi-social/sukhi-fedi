# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddActorTypeToAccounts do
  use Ecto.Migration

  @moduledoc """
  The AP actor `type` a local account publishes. "Person" for everyone
  who was already here; "Organization" for shared accounts made by
  `LocalAccounts.create_organization/2`.
  """

  def change do
    alter table(:accounts) do
      add :actor_type, :string, null: false, default: "Person"
    end
  end
end
