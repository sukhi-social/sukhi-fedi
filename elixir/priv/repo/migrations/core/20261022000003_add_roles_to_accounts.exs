# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddRolesToAccounts do
  use Ecto.Migration

  # Public badges an admin hands to a local account ("Moderator"). Each row is
  # `%{"name", "color"}` (shape fixed by `Account.changeset_roles/2`); empty =
  # no badge. Local rows only: a remote actor's roles are never mirrored.
  def change do
    alter table(:accounts) do
      add :roles, {:array, :map}, null: false, default: []
    end
  end
end
