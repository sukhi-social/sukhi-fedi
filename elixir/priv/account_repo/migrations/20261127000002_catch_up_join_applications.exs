# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountRepo.Migrations.CatchUpJoinApplications do
  @moduledoc false
  # What `SukhiFedi.Schema.JoinApplication` writes after a welcome: the
  # one-time entry key and the days. The address is emptied once the welcome
  # mail has gone, so it is nullable.
  use Ecto.Migration

  def change do
    alter table(:join_applications) do
      modify :email, :string, size: 254, null: true, from: {:string, size: 254, null: false}
      add :entry_hash, :string, size: 64
      add :entry_expires_at, :"timestamp(0)"
      add :welcomed_at, :"timestamp(0)"
      add :joined_at, :"timestamp(0)"
    end

    create unique_index(:join_applications, [:entry_hash], name: :join_applications_entry_hash_index)
  end
end
