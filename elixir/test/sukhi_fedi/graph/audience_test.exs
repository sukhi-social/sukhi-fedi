# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.AudienceTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Graph.Audience

  @pub "https://www.w3.org/ns/activitystreams#Public"
  @fol "https://h/u/a/followers"

  test "public in to is public; public only in cc is unlisted" do
    assert :public = Audience.visibility([@pub], [@fol], @fol)
    assert :unlisted = Audience.visibility([@fol], [@pub], @fol)
  end

  test "the author's followers alone is followers-only; anyone else is a letter" do
    assert :followers = Audience.visibility([@fol], [], @fol)
    assert :direct = Audience.visibility(["https://h/u/b"], [], @fol)
    assert :direct = Audience.visibility([@fol], [], nil)
  end

  test "iris accepts the shapes the wire uses" do
    assert ["a", "b"] = Audience.iris(["a", %{"id" => "b"}, "a", 3])
    assert ["a"] = Audience.iris("a")
    assert [] = Audience.iris(nil)
  end

  test "every ref attribute of the schema has a cleanup role" do
    {dependents, edges} = SukhiFedi.Graph.Sweep.classified_refs()

    refs =
      for {attr, p} <- SukhiFedi.Datalevin.SchemaFile.read(),
          p[:"db/valueType"] == :"db.type/ref",
          do: attr

    assert [] = refs -- (dependents ++ edges)
    assert [] = (dependents ++ edges) -- refs
  end
end
