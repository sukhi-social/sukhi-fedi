# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.TagsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.{Notes, Tags, Timelines}
  alias SukhiFedi.Schema.{Account, Tag}

  describe "Tags.extract/1" do
    test "lowercases and dedups" do
      assert Tags.extract("Hello #Elixir and #elixir and #世界") == ["elixir", "世界"]
    end

    test "ignores leading `&#…` HTML entities and 1-char tags" do
      assert Tags.extract("&#42; #a #ab") == ["ab"]
    end

    test "nil / empty → []" do
      assert Tags.extract(nil) == []
      assert Tags.extract("") == []
    end
  end

  describe "Notes.create_status emits hashtag rows" do
    test "tags upserted, note linked via note_tags" do
      a = create_account!("alice_tag")

      {:ok, _} =
        Notes.create_status(a, %{"status" => "I love #Elixir and #BEAM, #elixir"})

      assert %Tag{} = Repo.get_by(Tag, name: "elixir")
      assert %Tag{} = Repo.get_by(Tag, name: "beam")
    end

    test "tag timeline returns matching public notes only" do
      a = create_account!("alice_tl")
      b = create_account!("bob_tl")

      {:ok, _} = Notes.create_status(a, %{"status" => "post about #elixir"})
      {:ok, _} = Notes.create_status(b, %{"status" => "post about #ruby"})
      {:ok, _} = Notes.create_status(b, %{"status" => "another #elixir post", "visibility" => "followers"})

      results = Timelines.tag("elixir")

      assert length(results) == 1
      [%{account_id: aid}] = results
      assert aid == a.id
    end

    test "tag timeline is case-insensitive and accepts leading `#`" do
      a = create_account!("alice_ci")
      {:ok, _} = Notes.create_status(a, %{"status" => "ping #ExUnit"})

      assert [_] = Timelines.tag("exunit")
      assert [_] = Timelines.tag("#exunit")
      assert [_] = Timelines.tag("ExUnit")
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> insert_account!()
  end
end
