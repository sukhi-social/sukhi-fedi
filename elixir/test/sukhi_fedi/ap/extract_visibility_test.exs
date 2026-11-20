# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.ExtractVisibilityTest do
  use ExUnit.Case, async: true

  # Pure predicate, no DB — but the repo's local runner is
  # `make test-pgrust` (`--only integration`), so tag it to ride along.
  @moduletag :integration

  alias SukhiFedi.AP.Instructions.Extract

  @public_url "https://www.w3.org/ns/activitystreams#Public"

  describe "public?/1 spellings" do
    test "accepts the expanded URL, the compact as:Public, and the bare term" do
      assert Extract.public?(@public_url)
      assert Extract.public?("as:Public")
      assert Extract.public?("Public")
    end

    test "rejects anything else" do
      refute Extract.public?("https://example.com/users/bob")
      refute Extract.public?("as:public")
      refute Extract.public?(nil)
    end
  end

  describe "visibility_from/1 across spellings" do
    # The bug: a *fetched* object keeps the compact `as:Public`, which the
    # expanded-URL-only check missed, so public posts were stored direct.
    for spelling <- [@public_url, "as:Public", "Public"] do
      test "to: #{spelling} ⇒ public" do
        assert Extract.visibility_from(%{"to" => [unquote(spelling)]}) == "public"
      end

      test "cc: #{spelling} (to a person) ⇒ unlisted" do
        note = %{"to" => ["https://hollo.social/@x"], "cc" => [unquote(spelling)]}
        assert Extract.visibility_from(note) == "unlisted"
      end
    end

    test "followers addressing ⇒ followers" do
      note = %{"to" => ["https://hollo.social/@x/followers"]}
      assert Extract.visibility_from(note) == "followers"
    end

    test "no public marker anywhere ⇒ direct (a real DM)" do
      note = %{"to" => ["https://buttersc.one/users/afffx907uj"]}
      assert Extract.visibility_from(note) == "direct"
    end
  end

  describe "dm_addressing?/1" do
    test "compact as:Public means not a DM" do
      refute Extract.dm_addressing?(%{"to" => ["as:Public"]})
    end

    test "only personal recipients means a DM" do
      assert Extract.dm_addressing?(%{"to" => ["https://buttersc.one/users/afffx907uj"]})
    end
  end
end
