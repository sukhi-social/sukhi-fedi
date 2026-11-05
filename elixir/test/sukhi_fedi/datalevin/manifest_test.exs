# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.ManifestTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Datalevin.{Catalog, Config, Manifest}

  @schema %{
    ":a/x" => %{":db/valueType" => ":db.type/string", ":db/unique" => ":db.unique/identity"},
    ":a/y" => %{":db/valueType" => ":db.type/long"}
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "manifest_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{config: %Config{dir: dir}}
  end

  test "manifest path is inside the data directory" do
    assert Manifest.path(%Config{dir: "/var/lib/sukhi/datalevin"}) ==
             "/var/lib/sukhi/datalevin/.sukhi-store.json"
  end

  test "build records the version, the schema and the restore directory", %{config: config} do
    applied = [
      %{"version" => 3, "name" => "c", "applied_at" => "t"},
      %{"version" => 1, "name" => "a", "applied_at" => "t"}
    ]

    manifest = Manifest.build(config, :graph, @schema, applied)

    assert manifest["format"] == 2
    assert manifest["store"] == "datalevin"
    assert manifest["name"] == "graph"
    assert manifest["schema_version"] == 3
    assert manifest["schema"] == @schema
    assert manifest["migrating"] == nil
    assert manifest["data_dir"] == config.dir
    assert manifest["catalog_sha256"] =~ ~r/^[0-9a-f]{64}$/
  end

  test "an empty history is version 0", %{config: config} do
    assert Manifest.build(config, :main, @schema, [])["schema_version"] == 0
  end

  test "write then read gives the same manifest back, and leaves no temp file", %{config: config} do
    manifest = Manifest.build(config, :main, @schema, [%{"version" => 7, "name" => "m", "applied_at" => "t"}])

    assert :none = Manifest.read(config)
    assert :ok = Manifest.write!(config, manifest)
    assert {:ok, ^manifest} = Manifest.read(config)
    assert File.ls!(config.dir) == [Manifest.file_name()]
  end

  test "an unreadable manifest is an error, not a missing one", %{config: config} do
    File.mkdir_p!(config.dir)
    File.write!(Manifest.path(config), "{not json")

    assert {:error, message} = Manifest.read(config)
    assert message =~ "invalid store manifest"

    File.write!(Manifest.path(config), "[]")
    assert {:error, _} = Manifest.read(config)
  end

  test "the schema fingerprint ignores map order and changes with content" do
    reordered = %{":a/y" => @schema[":a/y"], ":a/x" => Map.new(Enum.reverse(Map.to_list(@schema[":a/x"])))}
    changed = put_in(@schema, [":a/y", ":db/valueType"], ":db.type/string")

    assert Manifest.schema_sha256(@schema) == Manifest.schema_sha256(reordered)
    refute Manifest.schema_sha256(@schema) == Manifest.schema_sha256(changed)
  end

  describe "validate_backup!/3" do
    setup %{config: config} do
      File.mkdir_p!(config.dir)
      queue = Path.join(config.dir, "queue.db")
      File.write!(queue, "")

      inventory = %{
        "format" => 1,
        "store" => "datalevin",
        "data_dir" => config.dir,
        "data_dir_manifest" => Manifest.path(config),
        "queue_db" => queue,
        "delivery_queue_db" => queue,
        "raw_backend" => "sqlite"
      }

      file = Path.join(config.dir, "backup-manifest.json")
      write = fn inv -> File.write!(file, JSON.encode!(inv)) end
      %{inventory: inventory, file: file, write: write}
    end

    test "a store at a version this release knows is accepted", ctx do
      ctx.write.(Map.put(ctx.inventory, "schema_version", 0))
      assert :ok = Manifest.validate_backup!(ctx.file, ctx.config, %{})
    end

    test "a store from a newer release is refused", ctx do
      ctx.write.(Map.put(ctx.inventory, "schema_version", 20_990_101_000_000))

      assert_raise ArgumentError, ~r/newer than this release knows/, fn ->
        Manifest.validate_backup!(ctx.file, ctx.config, %{})
      end
    end

    test "an inventory from before migrations must carry this catalog's old fingerprint", ctx do
      current = Manifest.legacy_sha256(Catalog.dtlv_schema())

      ctx.write.(Map.put(ctx.inventory, "catalog_sha256", current))
      assert :ok = Manifest.validate_backup!(ctx.file, ctx.config, %{})

      ctx.write.(Map.put(ctx.inventory, "catalog_sha256", "0000"))

      assert_raise ArgumentError, ~r/catalog fingerprint/, fn ->
        Manifest.validate_backup!(ctx.file, ctx.config, %{})
      end
    end

    test "a different data directory is refused", ctx do
      ctx.write.(ctx.inventory |> Map.put("schema_version", 0) |> Map.put("data_dir", "/elsewhere"))

      assert_raise ArgumentError, ~r/data directory path/, fn ->
        Manifest.validate_backup!(ctx.file, ctx.config, %{})
      end
    end
  end
end
