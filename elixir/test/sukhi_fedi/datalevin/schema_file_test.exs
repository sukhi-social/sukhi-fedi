# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.SchemaFileTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Datalevin.SchemaFile

  setup_all do
    %{schema: SchemaFile.read()}
  end

  test "the file is sound", %{schema: schema} do
    assert [] = SchemaFile.check(schema)
    assert map_size(schema) > 100
  end

  test "every raw has a ref and a size twin where the design says so", %{schema: schema} do
    for ns <- ~w(actor object activity) do
      assert Map.has_key?(schema, :"#{ns}/raw")
      assert Map.has_key?(schema, :"#{ns}/raw-ref")
    end

    assert Map.has_key?(schema, :"object/raw-size")
  end

  test "search text is a separate fulltext attribute; the original is not indexed", %{
    schema: schema
  } do
    assert schema[:"object/tokens"][:"db/fulltext"]
    refute schema[:"object/content-html"][:"db/fulltext"]
    refute Map.has_key?(schema, :"object/retained?")
  end

  test "the checker catches what dtlv would refuse" do
    bad =
      SchemaFile.parse(
        "{:a/x {:db/valueType :db.type/tuple} :a/y {:db/fulltext true :db/valueType :db.type/string}}"
      )

    assert [_, _] = SchemaFile.check(bad)
  end
end
