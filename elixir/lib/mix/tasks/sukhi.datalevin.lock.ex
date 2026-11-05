# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Sukhi.Datalevin.Lock do
  @moduledoc """
  Record the Datalevin schema of both stores in `priv/datalevin/schema.lock.json`.

      mix sukhi.datalevin.lock           # write it
      mix sukhi.datalevin.lock --check   # fail if it is stale (what the test does)

  Run it after `mix sukhi.datalevin.catalog` or an edit of `schema.edn`.
  A new attribute is taken as it is. A removed or changed one is refused
  until a migration newer than the lock's exists
  (`mix sukhi.datalevin.gen.migration`): see `SukhiFedi.Datalevin.SchemaLock`
  and docs/DATALEVIN_MIGRATIONS.md.
  """

  use Mix.Task

  alias SukhiFedi.Datalevin.SchemaLock

  @shortdoc "Record the Datalevin schemas; refuse unmigrated breaking changes"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {opts, _, _} = OptionParser.parse(args, strict: [check: :boolean])

    current = SchemaLock.current()

    lock =
      case SchemaLock.read() do
        {:ok, lock} -> lock
        {:error, _} -> %{main: %{version: 0, schema: %{}}, graph: %{version: 0, schema: %{}}}
      end

    if opts[:check], do: check(lock, current), else: write(lock, current)
  end

  defp check(lock, current) do
    case SchemaLock.check(lock, current) do
      [] ->
        Mix.shell().info("schema.lock.json is current")

      problems ->
        Mix.raise(
          "schema.lock.json is stale:\n  " <>
            Enum.join(problems, "\n  ") <> "\nRun `mix sukhi.datalevin.lock`."
        )
    end
  end

  defp write(lock, current) do
    case SchemaLock.update(lock, current) do
      {:ok, new} ->
        File.write!(SchemaLock.source_path(), SchemaLock.encode(new))
        Mix.shell().info("wrote #{SchemaLock.source_path()}")

      {:error, problems} ->
        Mix.raise("not locked:\n  " <> Enum.join(problems, "\n  "))
    end
  end
end
