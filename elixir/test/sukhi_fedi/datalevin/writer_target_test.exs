# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.WriterTargetTest do
  @moduledoc """
  An upsert names its conflict target as SQL (`{:unsafe_fragment, "(lower(email), purpose) WHERE …"}`)
  and the writer finds the unique index it means by comparing column lists. These are the two
  pure halves of that comparison; no `dtlv` needed.

  They were wrong for an expression column: the target text was cut at the first `)`, and the index
  side dropped `{:lower, col}` keys. Every second request for a signup code on the same address
  then raised `email_codes_signup_index` (Datalevin store only).
  """
  use ExUnit.Case, async: true

  alias SukhiFedi.Datalevin.{Catalog, Writer}

  describe "target_columns/1" do
    test "keeps a lower(...) column whole, and splits only at the top level" do
      assert Writer.target_columns(
               {:unsafe_fragment, "(lower(email), purpose) WHERE account_id IS NULL"}
             ) == ["lower(email)", "purpose"]
    end

    test "plain columns" do
      assert Writer.target_columns({:unsafe_fragment, "(shortcode) WHERE domain IS NULL"}) ==
               ["shortcode"]

      assert Writer.target_columns({:unsafe_fragment, "  (a, b)"}) == ["a", "b"]
    end

    test "a list of columns is taken as it is" do
      assert Writer.target_columns([:account_id, :purpose]) == [:account_id, :purpose]
    end
  end

  describe "unique_columns/1" do
    test "a plain column by name, a lowercased one as lower(col)" do
      assert Writer.unique_columns(%{keys: [lower: "email", col: "purpose"]}) ==
               ["lower(email)", "purpose"]

      assert Writer.unique_columns(%{keys: [col: "account_id", col: "purpose"]}) ==
               ["account_id", "purpose"]
    end
  end

  test "the signup-code index is what issue_signup's upsert target names" do
    unique = Enum.find(Catalog.table!("email_codes").unique, &(&1.name == "email_codes_signup_index"))

    target = {:unsafe_fragment, "(lower(email), purpose) WHERE account_id IS NULL"}

    assert Enum.sort(Writer.unique_columns(unique)) ==
             target |> Writer.target_columns() |> Enum.sort()
  end
end
