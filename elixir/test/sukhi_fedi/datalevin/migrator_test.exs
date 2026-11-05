# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.MigratorTest do
  @moduledoc """
  The migrator on a real `dtlv`. Tagged `:dtlv`; `test_helper.exs` leaves
  these out when no `dtlv` binary is found. Also `:integration`, because CI
  runs the dtlv-equipped suite as `--only integration` (`make test-pglite`)
  and the unit job has no `dtlv`.
  """

  use ExUnit.Case, async: false

  @moduletag :dtlv
  @moduletag :integration

  alias SukhiFedi.Datalevin.{Client, Config, Manifest, Migrator}
  alias SukhiFedi.Datalevin.Migration.{Ctx, Ops}

  @id %{":db/valueType" => ":db.type/long", ":db/unique" => ":db.unique/identity"}
  @old_schema %{
    ":t/id" => @id,
    ":t/old" => %{":db/valueType" => ":db.type/string"},
    ":t/labels" => %{":db/valueType" => ":db.type/string", ":db/cardinality" => ":db.cardinality/many"}
  }
  # What the next release wants: `old` is renamed to `new`, `labels` to
  # `tags`, and every row gets a `flag`.
  @new_schema %{
    ":t/id" => @id,
    ":t/new" => %{":db/valueType" => ":db.type/string"},
    ":t/tags" => %{":db/valueType" => ":db.type/string", ":db/cardinality" => ":db.cardinality/many"},
    ":t/flag" => %{":db/valueType" => ":db.type/boolean"}
  }

  defmodule Rename do
    use SukhiFedi.Datalevin.Migration, version: 20_260_101_000_000, store: :main

    @impl true
    def schema do
      %{
        ":t/old" => %{":db/valueType" => ":db.type/string"},
        ":t/labels" => %{
          ":db/valueType" => ":db.type/string",
          ":db/cardinality" => ":db.cardinality/many"
        }
      }
    end

    @impl true
    def up(ctx) do
      Ops.rename_attr!(ctx, :"t/old", :"t/new")
      Ops.rename_attr!(ctx, :"t/labels", :"t/tags")
      Ops.backfill!(ctx, :"t/id", :"t/flag", true)
      :ok
    end
  end

  defmodule Broken do
    use SukhiFedi.Datalevin.Migration, version: 20_260_101_000_001, store: :main

    @impl true
    def up(_ctx), do: raise("boom")
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "migrator_test_#{System.unique_integer([:positive])}")

    config =
      Config.from_env(%{
        "DATALEVIN_DIR" => Path.join(dir, "datalevin"),
        "DATALEVIN_BIN" => System.get_env("DATALEVIN_BIN", "dtlv"),
        "DATALEVIN_DURABILITY" => "nosync",
        "DATALEVIN_BATCH" => "1"
      })

    on_exit(fn -> File.rm_rf(dir) end)
    %{config: config, root: Path.join(dir, "datalevin-premigrate")}
  end

  defp spec(ctx, schema), do: Migrator.spec(:main, ctx.config, schema, ctx.root)

  # Open the store on its own for a moment.
  defp with_store(config, schema, fun) do
    {:ok, pid} = Client.start_link(name: :migrator_test_client, config: config, schema: schema)

    try do
      fun.(:migrator_test_client)
    after
      GenServer.stop(pid)
    end
  end

  defp seed(config, schema, tx), do: with_store(config, schema, &({:ok, _} = Client.transact(&1, tx)))

  defp rows(config, schema, edn) do
    with_store(config, schema, fn c ->
      {:ok, rows} = Client.query(c, edn)
      rows |> List.wrap() |> Enum.sort()
    end)
  end

  defp old_data,
    do: [
      %{":t/id" => 1, ":t/old" => "a", ":t/labels" => ["x", "y", "z"]},
      %{":t/id" => 2, ":t/old" => "b", ":t/labels" => ["x", "w"]},
      %{":t/id" => 3}
    ]

  describe "run!/2" do
    test "a new directory is created and every known migration is recorded as applied", ctx do
      assert :ok = Migrator.run!(spec(ctx, @new_schema), migrations: [Rename])

      assert {:ok, manifest} = Manifest.read(ctx.config)
      assert manifest["format"] == 2
      assert manifest["schema_version"] == 20_260_101_000_000
      assert manifest["schema"] == @new_schema
      assert [%{"version" => 20_260_101_000_000, "note" => "new store"}] = manifest["migrations"]
      assert File.dir?(ctx.config.dir)
      refute File.exists?(ctx.root)
    end

    test "running it again changes nothing", ctx do
      spec = spec(ctx, @new_schema)
      assert :ok = Migrator.run!(spec, migrations: [Rename])
      {:ok, first} = Manifest.read(ctx.config)

      assert :ok = Migrator.run!(spec, migrations: [Rename])
      {:ok, second} = Manifest.read(ctx.config)

      assert first["migrations"] == second["migrations"]
      assert first["schema"] == second["schema"]
    end

    test "a store stamped at the old schema is migrated: rename, backfill, copy first", ctx do
      assert :ok = Migrator.run!(spec(ctx, @old_schema), migrations: [])
      seed(ctx.config, @old_schema, old_data())

      assert {:ok, %{"schema_version" => 0}} = Manifest.read(ctx.config)
      assert :ok = Migrator.run!(spec(ctx, @new_schema), migrations: [Rename])

      assert {:ok, manifest} = Manifest.read(ctx.config)
      assert manifest["schema_version"] == 20_260_101_000_000
      assert manifest["schema"] == @new_schema
      assert manifest["migrating"] == nil

      assert [[1, "a"], [2, "b"]] ==
               rows(ctx.config, @new_schema, "[:find ?id ?n :where [?e :t/id ?id] [?e :t/new ?n]]")

      assert [[1, "x"], [1, "y"], [1, "z"], [2, "w"], [2, "x"]] ==
               rows(ctx.config, @new_schema, "[:find ?id ?t :where [?e :t/id ?id] [?e :t/tags ?t]]")

      assert [[1], [2], [3]] ==
               rows(ctx.config, @new_schema, "[:find ?id :where [?e :t/id ?id] [?e :t/flag true]]")

      assert [] == rows(ctx.config, @old_schema, "[:find ?e :where [?e :t/old _]]")
      assert [] == rows(ctx.config, @old_schema, "[:find ?e :where [?e :t/labels _]]")

      assert [backup] = File.ls!(ctx.root)
      assert backup =~ ~r/^main-\d{8}T\d{6}Z-before-20260101000000$/
      assert {:ok, %{"schema_version" => 0}} = Manifest.read(%{ctx.config | dir: Path.join(ctx.root, backup)})
    end

    test "a store without a manifest is taken as it stands and every migration runs", ctx do
      seed(ctx.config, @old_schema, old_data())
      refute File.exists?(Manifest.path(ctx.config))

      assert :ok = Migrator.run!(spec(ctx, @new_schema), migrations: [Rename])

      assert [[1, "a"], [2, "b"]] ==
               rows(ctx.config, @new_schema, "[:find ?id ?n :where [?e :t/id ?id] [?e :t/new ?n]]")
    end

    test "the copy can be turned off", ctx do
      config = %{ctx.config | premigrate_backup: false}
      assert :ok = Migrator.run!(Migrator.spec(:main, config, @old_schema, ctx.root), migrations: [])
      seed(config, @old_schema, old_data())

      assert :ok = Migrator.run!(Migrator.spec(:main, config, @new_schema, ctx.root), migrations: [Rename])
      refute File.exists?(ctx.root)
    end

    test "a removed attribute with no migration is refused, and nothing changes", ctx do
      assert :ok = Migrator.run!(spec(ctx, @old_schema), migrations: [])
      seed(ctx.config, @old_schema, old_data())
      {:ok, before} = Manifest.read(ctx.config)

      assert_raise ArgumentError, ~r/needs a migration.*removed: :t\/labels/s, fn ->
        Migrator.run!(spec(ctx, @new_schema), migrations: [])
      end

      assert {:ok, ^before} = Manifest.read(ctx.config)
    end

    test "a migration that raises stops the run, leaves a mark, and is run again next time", ctx do
      assert :ok = Migrator.run!(spec(ctx, @old_schema), migrations: [])
      seed(ctx.config, @old_schema, old_data())

      assert_raise RuntimeError, "boom", fn ->
        Migrator.run!(spec(ctx, @new_schema), migrations: [Rename, Broken])
      end

      {:ok, manifest} = Manifest.read(ctx.config)
      assert manifest["schema_version"] == 20_260_101_000_000
      assert %{"version" => 20_260_101_000_001} = manifest["migrating"]
      assert manifest["schema"] == @old_schema

      # Next time only the one that stopped is left.
      assert {:ok, %{pending: [%{module: Broken}]}} =
               Migrator.plan(manifest, Migrator.describe_all([Rename, Broken]), @new_schema)
    end

    test "data written by a newer release is refused", ctx do
      assert :ok = Migrator.run!(spec(ctx, @new_schema), migrations: [Rename])

      assert_raise ArgumentError, ~r/newer release/, fn ->
        Migrator.run!(spec(ctx, @new_schema), migrations: [])
      end
    end

    test "a format-1 manifest with another catalog is refused", ctx do
      File.mkdir_p!(ctx.config.dir)
      File.write!(Manifest.path(ctx.config), JSON.encode!(%{"format" => 1, "catalog_sha256" => "old"}))
      seed(ctx.config, @old_schema, old_data())

      assert_raise ArgumentError, ~r/incompatible/, fn ->
        Migrator.run!(spec(ctx, @new_schema), migrations: [])
      end
    end

    test "a format-1 manifest with this catalog is upgraded", ctx do
      File.mkdir_p!(ctx.config.dir)

      File.write!(
        Manifest.path(ctx.config),
        JSON.encode!(%{"format" => 1, "catalog_sha256" => Manifest.legacy_sha256(@old_schema)})
      )

      seed(ctx.config, @old_schema, old_data())

      assert :ok = Migrator.run!(spec(ctx, @old_schema), migrations: [])
      assert {:ok, %{"format" => 2, "schema" => @old_schema}} = Manifest.read(ctx.config)
    end
  end

  describe "check_current!/2" do
    test "passes without a manifest, fails with a migration pending, passes after run!", ctx do
      spec = spec(ctx, @new_schema)
      assert :ok = Migrator.check_current!(spec, migrations: [Rename])

      assert :ok = Migrator.run!(spec(ctx, @old_schema), migrations: [])
      assert_raise ArgumentError, ~r/migrate_all/, fn -> Migrator.check_current!(spec, migrations: [Rename]) end

      seed(ctx.config, @old_schema, old_data())
      assert :ok = Migrator.run!(spec, migrations: [Rename])
      assert :ok = Migrator.check_current!(spec, migrations: [Rename])
    end
  end

  describe "status/1" do
    test "reports a new, a pending and a current store", ctx do
      spec = spec(ctx, @new_schema)

      assert [%{state: :fresh, pending: []}] = Migrator.status(specs: [spec], migrations: [Rename])

      assert :ok = Migrator.run!(spec(ctx, @old_schema), migrations: [])

      assert [%{state: :pending, version: 0, pending: [20_260_101_000_000]}] =
               Migrator.status(specs: [spec], migrations: [Rename])

      seed(ctx.config, @old_schema, old_data())
      assert :ok = Migrator.run!(spec, migrations: [Rename])

      assert [%{state: :current, version: 20_260_101_000_000, pending: []}] =
               Migrator.status(specs: [spec], migrations: [Rename])
    end
  end

  describe "Ops" do
    test "rename_attr! keeps every value of a many-valued attribute, a batch of one at a time", ctx do
      seed(ctx.config, @old_schema, old_data())
      schema = Map.merge(@old_schema, @new_schema)

      with_store(ctx.config, schema, fn client ->
        op = %Ctx{client: client, config: ctx.config, store: :main}

        assert 2 == Ops.rename_attr!(op, :"t/labels", :"t/tags")
        # again: nothing left to do, nothing lost
        assert 0 == Ops.rename_attr!(op, :"t/labels", :"t/tags")
      end)

      assert [[1, "x"], [1, "y"], [1, "z"], [2, "w"], [2, "x"]] ==
               rows(ctx.config, schema, "[:find ?id ?t :where [?e :t/id ?id] [?e :t/tags ?t]]")
    end

    test "backfill! sets only what is missing, and only where the anchor is", ctx do
      seed(ctx.config, @new_schema, [%{":t/id" => 1, ":t/flag" => false}, %{":t/id" => 2}])

      with_store(ctx.config, @new_schema, fn client ->
        op = %Ctx{client: client, config: ctx.config, store: :main}
        assert 1 == Ops.backfill!(op, :"t/id", :"t/flag", true)
        assert 0 == Ops.backfill!(op, :"t/id", :"t/flag", true)
      end)

      assert [[1, false], [2, true]] ==
               rows(ctx.config, @new_schema, "[:find ?id ?f :where [?e :t/id ?id] [?e :t/flag ?f]]")
    end

    test "drop_entities! removes the whole row", ctx do
      seed(ctx.config, @old_schema, old_data())

      with_store(ctx.config, @old_schema, fn client ->
        op = %Ctx{client: client, config: ctx.config, store: :main}
        assert 2 == Ops.drop_entities!(op, :"t/old")
      end)

      assert [[3]] == rows(ctx.config, @old_schema, "[:find ?id :where [?e :t/id ?id]]")
    end
  end
end
