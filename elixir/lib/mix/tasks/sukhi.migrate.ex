# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Sukhi.Migrate do
  @moduledoc """
  Dev equivalent of `SukhiFedi.Release.migrate_all/0`: runs the versioned
  Datalevin migrations (docs/DATALEVIN_MIGRATIONS.md) against the dev store.
  """

  use Mix.Task

  @shortdoc "Run the Datalevin migrations"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    SukhiFedi.Release.migrate_all()
  end
end
