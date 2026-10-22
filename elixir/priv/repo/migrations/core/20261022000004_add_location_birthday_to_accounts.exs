# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddLocationBirthdayToAccounts do
  use Ecto.Migration

  # Misskey-style profile entries. Federated as `vcard:Address` / `vcard:bday`
  # (the keys Misskey and its forks read and write), so a remote row mirrors
  # the origin and a local one is visible to them. Both optional plain values.
  def change do
    alter table(:accounts) do
      add :location, :string
      add :birthday, :date
    end
  end
end
