# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Queue.Migrate do
  @moduledoc """
  Brings Oban's tables up to date at boot. Runs as a supervisor child that
  returns `:ignore`, so it has finished before the next child (the Oban
  instance) starts.

  It is keyed on Oban's own schema version, the way the gateway's
  `SukhiFedi.Queue.Migrate` is. Both nodes use one database, so whichever
  starts second finds the version already recorded and does nothing; the
  migrator's lock makes an overlap safe.
  """

  alias SukhiDelivery.QueueRepo

  defmodule Schema do
    @moduledoc false
    use Ecto.Migration

    def up, do: Oban.Migration.up()
    def down, do: Oban.Migration.down(version: 1)
  end

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  def start_link do
    version = Oban.Migrations.Postgres.current_version()
    Ecto.Migrator.run(QueueRepo, [{version, Schema}], :up, all: true, log: false)
    :ignore
  end
end
