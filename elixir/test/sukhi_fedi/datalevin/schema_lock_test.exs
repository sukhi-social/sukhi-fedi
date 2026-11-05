# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.SchemaLockTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Datalevin.SchemaLock

  @string %{":db/valueType" => ":db.type/string"}
  @long %{":db/valueType" => ":db.type/long"}

  defp lock(main, graph \\ %{}, mv \\ 0, gv \\ 0),
    do: %{main: %{version: mv, schema: main}, graph: %{version: gv, schema: graph}}

  # If this fails, the schema moved without the lock (or the lock without the
  # schema): `mix sukhi.datalevin.lock`. A removed or changed attribute needs
  # a migration first (`mix sukhi.datalevin.gen.migration`).
  test "priv/datalevin/schema.lock.json matches the schemas the code derives" do
    assert {:ok, committed} = SchemaLock.read()
    assert [] = SchemaLock.check(committed, SchemaLock.current())
  end

  describe "check/2" do
    test "equal locks have no problems" do
      assert [] = SchemaLock.check(lock(%{":a/x" => @string}), lock(%{":a/x" => @string}))
    end

    test "a new attribute makes the lock stale" do
      assert [problem] =
               SchemaLock.check(lock(%{":a/x" => @string}), lock(%{":a/x" => @string, ":a/y" => @long}))

      assert problem =~ "main: schema differs"
      assert problem =~ "added: :a/y"
    end

    test "a newer migration makes the lock stale" do
      assert [problem] = SchemaLock.check(lock(%{}, %{}, 0, 0), lock(%{}, %{}, 0, 20_260_101_000_000))
      assert problem =~ "graph: newest migration is 20260101000000"
    end
  end

  describe "update/2" do
    test "additive changes are taken" do
      old = lock(%{":a/x" => @string})
      new = lock(%{":a/x" => @string, ":a/y" => @long})

      assert {:ok, ^new} = SchemaLock.update(old, new)
    end

    test "a removed attribute is refused without a newer migration" do
      old = lock(%{":a/x" => @string, ":a/y" => @long})
      new = lock(%{":a/x" => @string})

      assert {:error, [problem]} = SchemaLock.update(old, new)
      assert problem =~ "main: removed: :a/y"
      assert problem =~ "gen.migration NAME --store main"
    end

    test "a changed attribute is refused in the store it changed in" do
      old = lock(%{}, %{":b/x" => @string})
      new = lock(%{}, %{":b/x" => @long})

      assert {:error, [problem]} = SchemaLock.update(old, new)
      assert problem =~ "graph: changed: :b/x"
    end

    test "a removed attribute is taken once a migration newer than the lock exists" do
      old = lock(%{":a/x" => @string, ":a/y" => @long})
      new = lock(%{":a/x" => @string}, %{}, 20_260_101_000_000, 0)

      assert {:ok, ^new} = SchemaLock.update(old, new)
    end

    test "a migration of the other store does not excuse it" do
      old = lock(%{":a/x" => @string, ":a/y" => @long})
      new = lock(%{":a/x" => @string}, %{}, 0, 20_260_101_000_000)

      assert {:error, [_]} = SchemaLock.update(old, new)
    end
  end

  test "encode then read round-trips, one attribute per line" do
    original =
      lock(
        %{":a/x" => Map.put(@string, ":db/unique", ":db.unique/identity"), ":a/y" => @long},
        %{":b/z" => %{":db/valueType" => ":db.type/tuple", ":db/tupleAttrs" => [":b/x", ":b/y"]}},
        20_260_101_000_000,
        0
      )

    text = SchemaLock.encode(original)
    path = Path.join(System.tmp_dir!(), "schema_lock_#{System.unique_integer([:positive])}.json")
    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, ^original} = SchemaLock.read(path)
    assert text |> String.split("\n") |> Enum.count(&String.contains?(&1, "\":a/")) == 2
    assert String.ends_with?(text, "}\n")
  end

  test "reading a missing file is an error, not a crash" do
    assert {:error, message} = SchemaLock.read("/nonexistent/schema.lock.json")
    assert message =~ "cannot read"
  end
end
