# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.SchemaDiffTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Datalevin.SchemaDiff

  @string %{":db/valueType" => ":db.type/string"}
  @long %{":db/valueType" => ":db.type/long"}

  test "identical schemas have an empty diff" do
    schema = %{":a/x" => @string, ":a/y" => @long}
    diff = SchemaDiff.diff(schema, schema)

    assert SchemaDiff.empty?(diff)
    assert SchemaDiff.additive?(diff)
    assert SchemaDiff.breaking(diff) == []
  end

  test "a new attribute is additive" do
    diff = SchemaDiff.diff(%{":a/x" => @string}, %{":a/x" => @string, ":a/z" => @long})

    assert %{added: [":a/z"], removed: [], changed: []} = diff
    assert SchemaDiff.additive?(diff)
    refute SchemaDiff.empty?(diff)
  end

  test "a removed attribute is not additive" do
    diff = SchemaDiff.diff(%{":a/x" => @string, ":a/y" => @long}, %{":a/x" => @string})

    assert %{removed: [":a/y"]} = diff
    refute SchemaDiff.additive?(diff)
    assert SchemaDiff.breaking(diff) == [":a/y"]
  end

  test "a changed definition is not additive" do
    diff = SchemaDiff.diff(%{":a/x" => @string}, %{":a/x" => @long})

    assert [{":a/x", @string, @long}] = diff.changed
    refute SchemaDiff.additive?(diff)
  end

  test "an added index flag is a change: only a new attribute is safe" do
    indexed = Map.put(@string, ":db/index", true)
    diff = SchemaDiff.diff(%{":a/x" => @string}, %{":a/x" => indexed})

    refute SchemaDiff.additive?(diff)
  end

  test "documentation is not part of the schema" do
    documented = Map.put(@string, ":db/doc", "what it is")
    diff = SchemaDiff.diff(%{":a/x" => @string}, %{":a/x" => documented})

    assert SchemaDiff.empty?(diff)
  end

  test "breaking lists removed and changed attributes together, sorted" do
    old = %{":a/x" => @string, ":a/y" => @long, ":a/z" => @long}
    new = %{":a/x" => @long, ":a/z" => @long}

    assert SchemaDiff.breaking(SchemaDiff.diff(old, new)) == [":a/x", ":a/y"]
  end

  test "describe names what changed and cuts a long list" do
    old = Map.new(1..12, &{":a/r#{&1}", @string})
    text = SchemaDiff.describe(SchemaDiff.diff(old, %{":a/n" => @string}))

    assert text =~ "removed: :a/r1"
    assert text =~ "(+4 more)"
    assert text =~ "added: :a/n"
  end
end
