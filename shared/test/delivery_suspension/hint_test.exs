# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.HintTest do
  use ExUnit.Case, async: true

  alias SukhiShared.DeliverySuspension.Hint

  @asked "https://rest.example/inbox"
  @rel "https://w3id.org/fep/f799#deliverySuspension"
  @notice "https://rest.example/suspensions/1"

  defp link(target, rel \\ @rel), do: "<#{target}>; rel=\"#{rel}\""

  test "the link with the rel is the hint, whatever the header's name case or shape" do
    assert {:ok, @notice} = Hint.notice_url(%{"link" => [link(@notice)]}, @asked)
    assert {:ok, @notice} = Hint.notice_url(%{"Link" => link(@notice)}, @asked)
    assert {:ok, @notice} = Hint.notice_url([{"Link", link(@notice)}], @asked)
  end

  test "other links, and other rels, are passed over; the first of ours wins" do
    other = "<https://rest.example/x>; rel=\"next\", " <> link(@notice)
    assert {:ok, @notice} = Hint.notice_url(%{"link" => [other]}, @asked)

    two = [link("https://rest.example/a"), link("https://rest.example/b")]
    assert {:ok, "https://rest.example/a"} = Hint.notice_url(%{"link" => two}, @asked)

    assert {:ok, @notice} =
             Hint.notice_url(
               %{"link" => [link("https://rest.example/n", "next"), link(@notice)]},
               @asked
             )

    assert :none = Hint.notice_url(%{"link" => [link(@notice, "next")]}, @asked)
  end

  test "rel may be one of several, or bare" do
    assert {:ok, @notice} =
             Hint.notice_url(%{"link" => [link(@notice, "alternate " <> @rel)]}, @asked)

    assert {:ok, @notice} = Hint.notice_url(%{"link" => ["<#{@notice}>; rel=#{@rel}"]}, @asked)
    assert :none = Hint.notice_url(%{"link" => [link(@notice, @rel <> "x")]}, @asked)
  end

  test "a relative target is resolved against what was asked; the fragment goes" do
    assert {:ok, "https://rest.example/s/1"} =
             Hint.notice_url(%{"link" => [link("/s/1#top")]}, @asked)
  end

  test "only an https URL without credentials is a hint (the address itself is guarded when it is fetched)" do
    assert :none = Hint.notice_url(%{"link" => [link("http://rest.example/s/1")]}, @asked)
    assert :none = Hint.notice_url(%{"link" => [link("https://u:p@rest.example/s/1")]}, @asked)
    assert :none = Hint.notice_url(%{"link" => [link("")]}, @asked)

    long = "https://rest.example/" <> String.duplicate("a", 2100)
    assert :none = Hint.notice_url(%{"link" => [link(long)]}, @asked)
  end

  test "no header, or nonsense, is no hint" do
    assert :none = Hint.notice_url(%{}, @asked)
    assert :none = Hint.notice_url(nil, @asked)
    assert :none = Hint.notice_url(%{"link" => ["garbage"]}, @asked)
    assert :none = Hint.notice_url(%{"link" => [nil, 3]}, @asked)
  end
end
