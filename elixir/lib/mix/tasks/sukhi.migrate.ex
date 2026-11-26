# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Sukhi.Migrate do
  @moduledoc """
  Dev equivalent of `SukhiFedi.Release.migrate_all/0`.
  """

  use Mix.Task

  @shortdoc "Open the store (nothing to migrate)"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    SukhiFedi.Release.migrate_all()
  end
end
