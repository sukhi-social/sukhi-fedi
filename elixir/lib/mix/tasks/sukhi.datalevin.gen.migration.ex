# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Sukhi.Datalevin.Gen.Migration do
  @moduledoc """
  Write the skeleton of a Datalevin migration.

      mix sukhi.datalevin.gen.migration drop_old_flag
      mix sukhi.datalevin.gen.migration backfill_sid --store graph

  The file goes to `lib/sukhi_fedi/datalevin/migrations/`, versioned with the
  current UTC time. Edit `up/1`, then run `mix sukhi.datalevin.lock`.
  What a migration may rely on, and must not do:
  `SukhiFedi.Datalevin.Migration`, docs/DATALEVIN_MIGRATIONS.md.
  """

  use Mix.Task

  @shortdoc "Create a Datalevin migration"

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [store: :string])

    name =
      case rest do
        [name] -> name
        _ -> Mix.raise("usage: mix sukhi.datalevin.gen.migration NAME [--store main|graph]")
      end

    unless name =~ ~r/^[a-z][a-z0-9_]*$/,
      do: Mix.raise("NAME is lower_snake_case, like drop_old_flag; got #{inspect(name)}")

    store = Keyword.get(opts, :store, "main")
    unless store in ["main", "graph"], do: Mix.raise("--store is main or graph, got #{inspect(store)}")

    version = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    module = "V#{version}#{Macro.camelize(name)}"
    dir = Path.join(["lib", "sukhi_fedi", "datalevin", "migrations"])
    file = Path.join(dir, "v#{version}_#{name}.ex")

    File.mkdir_p!(dir)
    File.write!(file, template(module, version, store))
    Mix.shell().info("created #{file}")
  end

  @doc false
  def template(module, version, store) do
    """
    # SPDX-License-Identifier: AGPL-3.0-or-later
    defmodule SukhiFedi.Datalevin.Migrations.#{module} do
      @moduledoc \"\"\"
      TODO: what changed in the schema, and what happens to the data.
      \"\"\"

      use SukhiFedi.Datalevin.Migration, version: #{version}, store: :#{store}

      # Attributes this migration reads that the current schema no longer
      # defines (a removed or renamed column), in wire form:
      #
      #     %{":accounts/old_flag" => %{":db/valueType" => ":db.type/boolean"}}
      @impl true
      def schema, do: %{}

      # Idempotent: it may be stopped anywhere and is then run again.
      # Ops: backfill!/4, rename_attr!/3, retract_attr!/2, drop_entities!/2,
      # query!/2, transact!/2.
      @impl true
      def up(_ctx) do
        :ok
      end
    end
    """
  end
end
