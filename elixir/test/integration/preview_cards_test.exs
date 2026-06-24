# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.PreviewCardsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.PreviewCards
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Note, PreviewCard}

  describe "for_notes/1" do
    test "returns stored cards keyed by note id" do
      alice = %Account{username: "alice_pc", display_name: "alice", summary: ""} |> Repo.insert!()
      note = %Note{account_id: alice.id, content: "see example.com", visibility: "public"} |> Repo.insert!()

      %PreviewCard{
        note_id: note.id,
        url: "https://example.com/p",
        title: "Example",
        description: "a page",
        image: "https://cdn.example/i.png",
        type: "link",
        provider_name: "Example"
      }
      |> Repo.insert!()

      cards = PreviewCards.for_notes([note.id])

      assert %{title: "Example", url: "https://example.com/p", provider_name: "Example"} =
               cards[note.id]
    end

    test "is empty for a note with no card" do
      alice = %Account{username: "bob_pc", display_name: "bob", summary: ""} |> Repo.insert!()
      note = %Note{account_id: alice.id, content: "no links", visibility: "public"} |> Repo.insert!()

      assert PreviewCards.for_notes([note.id]) == %{}
    end
  end
end
