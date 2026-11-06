# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.RecipientsTest do
  use ExUnit.Case, async: true

  alias SukhiDelivery.Outbox.Recipients
  alias SukhiDelivery.Schema.Account

  # Who gets a Like / Announce / poll ballot is the note's author. The URL of
  # the note says nothing reliable about that: Misskey's is `/notes/<id>` and
  # Pleroma's is `/objects/<uuid>`, neither contains the actor.
  @misskey_note "https://misskey.example/notes/9abcdefghi"
  @pleroma_note "https://pleroma.example/objects/6a3c1f9e-0000-4000-8000-000000000000"
  @mastodon_note "https://mastodon.example/users/alice/statuses/110000000000000000"

  describe "author_endpoints_of/1 — the author's own row, not the note URL" do
    test "a remote author gives the inbox the actor JSON declared (shared inbox first)" do
      a = %Account{
        domain: "misskey.example",
        actor_uri: "https://misskey.example/users/9xyz",
        inbox_url: "https://misskey.example/users/9xyz/inbox",
        shared_inbox_url: "https://misskey.example/inbox"
      }

      assert {"https://misskey.example/users/9xyz", "https://misskey.example/inbox"} =
               Recipients.author_endpoints_of(a)
    end

    test "without a shared inbox, the personal inbox" do
      a = %Account{
        domain: "misskey.example",
        actor_uri: "https://misskey.example/users/9xyz",
        inbox_url: "https://misskey.example/users/9xyz/inbox"
      }

      assert {_, "https://misskey.example/users/9xyz/inbox"} = Recipients.author_endpoints_of(a)
    end

    test "a remote row with no actor_uri, or no row at all, says nothing" do
      assert nil == Recipients.author_endpoints_of(%Account{domain: "misskey.example"})
      assert nil == Recipients.author_endpoints_of(nil)
    end
  end

  describe "note_author_inbox/2 — falls back to the URL guess only without an author" do
    test "no author id: Mastodon-shaped URLs still work" do
      assert ["https://mastodon.example/users/alice/inbox"] =
               Recipients.note_author_inbox(@mastodon_note, nil)
    end

    test "no author id: Misskey and Pleroma URLs give nothing (why the author id matters)" do
      assert [] = Recipients.note_author_inbox(@misskey_note, nil)
      assert [] = Recipients.note_author_inbox(@pleroma_note, nil)
    end

    test "an author id that is not a number is no author (never a crash)" do
      assert [] = Recipients.note_author_inbox(@misskey_note, "not-an-int")
    end
  end
end
