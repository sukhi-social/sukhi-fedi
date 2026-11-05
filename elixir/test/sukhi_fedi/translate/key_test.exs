# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Translate.KeyTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Translate.Key

  @free "0c1d2e3f-4a5b-6c7d-8e9f-a0b1c2d3e4f5:fx"
  @pro "0c1d2e3f-4a5b-6c7d-8e9f-a0b1c2d3e4f5"

  test "a sealed key opens for the same account, and shows only its last four characters" do
    assert {:ok, sealed, "e4f5"} = Key.seal(@pro, 7)
    assert {:ok, @pro} = Key.open(sealed, 7)

    # The Free plan's `:fx` is a suffix, not part of the key: the hint is the same.
    assert {:ok, sealed_free, "e4f5"} = Key.seal(@free, 7)
    assert {:ok, @free} = Key.open(sealed_free, 7)
  end

  test "the plaintext is nowhere in what is stored" do
    {:ok, sealed, _} = Key.seal(@pro, 7)
    refute String.contains?(sealed, @pro)
    refute String.contains?(sealed, "c2d3e4f5")
  end

  test "a sealed key does not open on another account" do
    {:ok, sealed, _} = Key.seal(@pro, 7)
    assert :error = Key.open(sealed, 8)
  end

  test "what is not a DeepL key is refused" do
    for bad <- ["", "hello", "0c1d2e3f-4a5b-6c7d-8e9f", @pro <> "x", "  " <> "not a key  "] do
      assert :error = Key.seal(bad, 7), "accepted #{inspect(bad)}"
    end
  end

  test "surrounding spaces from a paste are not part of the key" do
    assert {:ok, sealed, _} = Key.seal("  " <> @pro <> "\n", 7)
    assert {:ok, @pro} = Key.open(sealed, 7)
  end

  test "nothing opens from nothing or from garbage" do
    assert :error = Key.open(nil, 7)
    assert :error = Key.open("not sealed", 7)
  end
end
