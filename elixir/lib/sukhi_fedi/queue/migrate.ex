# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Queue.Migrate do
  @moduledoc """
  Brings the queue database up to date at boot: Oban's tables, and the
  `raw_blobs` table of `SukhiFedi.RawStore.Postgres`. Returns `:ignore`, so it
  has finished before the next child (Oban) starts.

  The migration is keyed on Oban's own schema version, so a newer Oban runs its
  `up/0` once more and applies only the difference. The delivery node runs the
  same thing against the same database (`SukhiDelivery.Queue.Migrate`); the
  migrator's lock makes the two safe to overlap.
  """

  defmodule Schema do
    @moduledoc false
    use Ecto.Migration

    def up, do: Oban.Migration.up()
    def down, do: Oban.Migration.down(version: 1)
  end

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}

  def start_link do
    version = Oban.Migrations.Postgres.current_version()
    Ecto.Migrator.run(SukhiFedi.QueueRepo, [{version, Schema}], :up, all: true, log: false)
    SukhiFedi.RawStore.Postgres.ensure_table(SukhiFedi.QueueRepo)
    :ignore
  end
end
