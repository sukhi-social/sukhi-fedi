# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.WebFingerResourceTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Federation.WebFinger

  describe "parse_resource/1" do
    test "a handle is asked as acct:, with or without the leading @" do
      assert WebFinger.parse_resource("@kuro43_@sukhi.social") ==
               {:ok, {"sukhi.social", "acct:kuro43_@sukhi.social"}}

      assert WebFinger.parse_resource(" kuro43_@sukhi.social ") ==
               {:ok, {"sukhi.social", "acct:kuro43_@sukhi.social"}}
    end

    test "a URL (actor URI or profile page) is asked as itself, of its own host" do
      assert WebFinger.parse_resource("https://sukhi.social/@kuro43_") ==
               {:ok, {"sukhi.social", "https://sukhi.social/@kuro43_"}}

      assert WebFinger.parse_resource("https://sukhi.social/users/kuro43_") ==
               {:ok, {"sukhi.social", "https://sukhi.social/users/kuro43_"}}

      assert WebFinger.parse_resource("https://h.example:8443/@bob") ==
               {:ok, {"h.example:8443", "https://h.example:8443/@bob"}}
    end

    test "anything else cannot be asked" do
      for input <- ["", "not a url", "@@x", "a@b@c", "ftp://h.example/@bob", "https://"] do
        assert WebFinger.parse_resource(input) == :error, input
      end
    end
  end
end
