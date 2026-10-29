# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Queue.Migrate do
  @moduledoc """
  Creates the `oban_jobs` tables in the queue SQLite file at boot. Runs as a
  supervisor child that returns `:ignore`, so it finishes before the next
  child (the Oban instance) starts.
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
    Ecto.Migrator.run(QueueRepo, [{0, Schema}], :up, all: true, log: false)
    :ignore
  end
end
