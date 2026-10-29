# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Queue.Migrate do
  @moduledoc """
  Creates the `oban_jobs` tables in the queue SQLite file at boot. Returns
  `:ignore`, so it has finished before the next child (Oban) starts.
  """

  defmodule Schema do
    @moduledoc false
    use Ecto.Migration

    def up, do: Oban.Migration.up()
    def down, do: Oban.Migration.down(version: 1)
  end

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}

  def start_link do
    Ecto.Migrator.run(SukhiFedi.QueueRepo, [{0, Schema}], :up, all: true, log: false)
    :ignore
  end
end
