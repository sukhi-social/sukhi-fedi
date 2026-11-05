# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.MigratorPlanTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Datalevin.{Config, Manifest, Migrator}

  @string %{":db/valueType" => ":db.type/string"}
  @long %{":db/valueType" => ":db.type/long"}

  defp d(version, store \\ :main),
    do: %{module: Module.concat(__MODULE__, "M#{version}"), version: version, store: store, description: "m#{version}"}

  defp manifest(schema, versions) do
    applied = Enum.map(versions, &%{"version" => &1, "name" => "m#{&1}", "applied_at" => "t"})
    Manifest.build(%Config{dir: "/nowhere"}, :main, schema, applied)
  end

  describe "plan/3" do
    test "a store that has everything and no drift has nothing to do" do
      schema = %{":a/x" => @string}

      assert {:ok, %{pending: [], drift: drift}} =
               Migrator.plan(manifest(schema, [1, 2]), [d(1), d(2)], schema)

      assert drift.added == []
    end

    test "migrations not yet applied are pending, oldest first as given" do
      schema = %{":a/x" => @string}

      assert {:ok, %{pending: [%{version: 3}, %{version: 4}]}} =
               Migrator.plan(manifest(schema, [1, 2]), [d(1), d(2), d(3), d(4)], schema)
    end

    test "new attributes alone need no migration" do
      old = %{":a/x" => @string}
      new = %{":a/x" => @string, ":a/y" => @long}

      assert {:ok, %{pending: [], drift: %{added: [":a/y"]}}} =
               Migrator.plan(manifest(old, []), [], new)
    end

    test "a removed attribute with nothing pending is refused" do
      old = %{":a/x" => @string, ":a/y" => @long}
      new = %{":a/x" => @string}

      assert {:error, {:unmigrated, %{removed: [":a/y"]}}} =
               Migrator.plan(manifest(old, []), [], new)
    end

    test "a removed attribute is allowed through when a migration is pending" do
      old = %{":a/x" => @string, ":a/y" => @long}
      new = %{":a/x" => @string}

      assert {:ok, %{pending: [%{version: 1}]}} =
               Migrator.plan(manifest(old, []), [d(1)], new)
    end

    test "migrations the release does not know mean newer data" do
      schema = %{":a/x" => @string}

      assert {:error, {:unknown_migrations, [5, 9]}} =
               Migrator.plan(manifest(schema, [1, 5, 9]), [d(1)], schema)
    end

    test "a pending migration older than an applied one is refused" do
      schema = %{":a/x" => @string}

      assert {:error, {:out_of_order, [2]}} =
               Migrator.plan(manifest(schema, [1, 3]), [d(1), d(2), d(3)], schema)
    end
  end

  describe "explain/2" do
    test "each reason says what to do" do
      spec = Migrator.spec(:main, %Config{dir: "/data"}, %{}, "/backups")

      assert Migrator.explain({:unknown_migrations, [7]}, spec) =~ "newer release"
      assert Migrator.explain({:out_of_order, [2]}, spec) =~ "Rename"
      assert Migrator.explain({:pending, [d(3)]}, spec) =~ "migrate_all"

      unmigrated =
        Migrator.explain(
          {:unmigrated, %{added: [], removed: [":a/y"], changed: []}},
          spec
        )

      assert unmigrated =~ "gen.migration"
      assert unmigrated =~ ":a/y"
    end
  end

  describe "describe_all/1" do
    defmodule One do
      use SukhiFedi.Datalevin.Migration, version: 20_260_101_000_000, store: :main
      @impl true
      def up(_), do: :ok
    end

    defmodule Two do
      use SukhiFedi.Datalevin.Migration, version: 20_260_101_000_001, store: :graph

      @impl true
      def description, do: "second"
      @impl true
      def up(_), do: :ok
    end

    defmodule Clash do
      use SukhiFedi.Datalevin.Migration, version: 20_260_101_000_000, store: :main
      @impl true
      def up(_), do: :ok
    end

    defmodule NotAMigration do
    end

    test "sorts by version and ignores modules that are not migrations" do
      assert [%{module: One, store: :main}, %{module: Two, store: :graph, description: "second"}] =
               Migrator.describe_all([Two, NotAMigration, One])
    end

    test "the description defaults to the module name" do
      assert [%{description: "one"}] = Migrator.describe_all([One])
    end

    test "two migrations with the same store and version raise" do
      assert_raise ArgumentError, ~r/share store=main version=20260101000000/, fn ->
        Migrator.describe_all([One, Clash])
      end
    end

    test "the same version in different stores is fine" do
      assert length(Migrator.describe_all([One, Two])) == 2
    end

    test "latest_version is per store" do
      ds = Migrator.describe_all([One, Two])

      assert Migrator.latest_version(:main, ds) == 20_260_101_000_000
      assert Migrator.latest_version(:graph, ds) == 20_260_101_000_001
      assert Migrator.latest_version(:main, []) == 0
    end
  end

  test "using the macro with a bad version or store fails at compile time" do
    assert_raise ArgumentError, ~r/positive integer/, fn ->
      Code.compile_string("""
      defmodule SukhiFedi.Datalevin.MigratorPlanTest.BadVersion do
        use SukhiFedi.Datalevin.Migration, version: "x"
      end
      """)
    end

    assert_raise ArgumentError, ~r/:main or :graph/, fn ->
      Code.compile_string("""
      defmodule SukhiFedi.Datalevin.MigratorPlanTest.BadStore do
        use SukhiFedi.Datalevin.Migration, version: 1, store: :other
      end
      """)
    end
  end
end
