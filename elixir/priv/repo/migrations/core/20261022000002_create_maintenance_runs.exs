# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.CreateMaintenanceRuns do
  use Ecto.Migration

  @moduledoc """
  One row per run of a `SukhiFedi.Maintenance.*` script, so `/admin` can show
  what a long `bin/sukhi_fedi rpc '…run(:execute)'` is doing right now.

  Lives in the DB rather than ETS because the script runs in its own process
  (and, during a deploy overlap, maybe on the other gateway than the one
  serving the admin page). The script writes at most about once a second —
  see `SukhiFedi.Maintenance.Progress` — so `updated_at` doubles as a
  heartbeat: a `running` row that has gone quiet for a while is shown as
  "may have stopped", never claimed as failed.
  """

  def change do
    create table(:maintenance_runs) do
      add(:name, :string, null: false)
      add(:mode, :string, null: false)
      add(:state, :string, null: false, default: "running")
      add(:stage, :string)
      add(:total, :integer, null: false, default: 0)
      add(:done, :integer, null: false, default: 0)
      add(:failed, :integer, null: false, default: 0)
      add(:last_error, :text)
      add(:summary, :map, null: false, default: %{})
      add(:started_at, :utc_datetime, null: false)
      add(:finished_at, :utc_datetime)
      add(:updated_at, :utc_datetime, null: false)
    end

    create(index(:maintenance_runs, [:started_at]))
    create(index(:maintenance_runs, [:state]))
  end
end
