# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.InteractionsTest do
  @moduledoc """
  PR3.5 — favourite/reblog/bookmark/pin end-to-end on the gateway.

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.Notes
  alias SukhiFedi.Schema.{Account, Boost, Bookmark, OutboxEvent, PinnedNote, Reaction}

  describe "favourite/2" do
    test "inserts Reaction + emits sns.outbox.like.created" do
      a = create_account!("alice_fav")
      b = create_account!("bob_fav")
      {:ok, n} = Notes.create_status(b, %{"status" => "hi"})

      assert {:ok, _} = Notes.favourite(a, n.id)

      assert Repo.get_by!(Reaction, account_id: a.id, note_id: n.id, emoji: "⭐")

      assert Repo.exists?(
               from e in OutboxEvent, where: e.subject == "sns.outbox.like.created"
             )
    end

    test "the event names the note's author, so delivery needn't guess from the note URL" do
      # Misskey (`/notes/<id>`) and Pleroma (`/objects/<uuid>`) URLs carry no
      # actor; the favourite went nowhere until the author rode along.
      a = create_account!("alice_fav_au")
      b = create_account!("bob_fav_au")
      {:ok, n} = Notes.create_status(b, %{"status" => "hi"})

      {:ok, _} = Notes.favourite(a, n.id)

      assert %OutboxEvent{payload: payload} =
               Repo.one!(from e in OutboxEvent, where: e.subject == "sns.outbox.like.created")

      assert payload["note_author_id"] == b.id
      assert payload["account_id"] == a.id
    end

    test "is idempotent — second call no-op, no extra outbox row" do
      a = create_account!("alice_fav_id")
      b = create_account!("bob_fav_id")
      {:ok, n} = Notes.create_status(b, %{"status" => "hi"})

      {:ok, _} = Notes.favourite(a, n.id)
      {:ok, _} = Notes.favourite(a, n.id)

      assert Repo.aggregate(
               from(e in OutboxEvent,
                 where: e.subject == "sns.outbox.like.created"
               ),
               :count,
               :id
             ) == 1
    end
  end

  describe "unfavourite/2" do
    test "deletes Reaction + emits sns.outbox.like.undone" do
      a = create_account!("alice_unfav")
      b = create_account!("bob_unfav")
      {:ok, n} = Notes.create_status(b, %{"status" => "hi"})
      {:ok, _} = Notes.favourite(a, n.id)

      assert {:ok, _} = Notes.unfavourite(a, n.id)

      refute Repo.get_by(Reaction, account_id: a.id, note_id: n.id, emoji: "⭐")

      assert Repo.exists?(
               from e in OutboxEvent, where: e.subject == "sns.outbox.like.undone"
             )
    end
  end

  describe "react/3" do
    test "inserts a custom-emoji Reaction + emits sns.outbox.reaction.created" do
      a = create_account!("alice_react")
      b = create_account!("bob_react")
      {:ok, n} = Notes.create_status(b, %{"status" => "hi"})

      assert {:ok, _} = Notes.react(a, n.id, "🦊")

      assert Repo.get_by!(Reaction, account_id: a.id, note_id: n.id, emoji: "🦊")

      assert Repo.exists?(
               from e in OutboxEvent, where: e.subject == "sns.outbox.reaction.created"
             )
    end

    test "is idempotent per (account, note, emoji)" do
      a = create_account!("alice_react_id")
      b = create_account!("bob_react_id")
      {:ok, n} = Notes.create_status(b, %{"status" => "hi"})

      {:ok, _} = Notes.react(a, n.id, "🦊")
      {:ok, _} = Notes.react(a, n.id, "🦊")

      assert Repo.aggregate(
               from(e in OutboxEvent, where: e.subject == "sns.outbox.reaction.created"),
               :count,
               :id
             ) == 1
    end
  end

  describe "unreact/3" do
    test "deletes the Reaction + emits sns.outbox.reaction.undone" do
      a = create_account!("alice_unreact")
      b = create_account!("bob_unreact")
      {:ok, n} = Notes.create_status(b, %{"status" => "hi"})
      {:ok, _} = Notes.react(a, n.id, "🦊")

      assert {:ok, _} = Notes.unreact(a, n.id, "🦊")

      refute Repo.get_by(Reaction, account_id: a.id, note_id: n.id, emoji: "🦊")

      assert Repo.exists?(
               from e in OutboxEvent, where: e.subject == "sns.outbox.reaction.undone"
             )
    end
  end

  describe "reblog/2" do
    test "inserts Boost + emits sns.outbox.announce.created" do
      a = create_account!("alice_rb")
      b = create_account!("bob_rb")
      {:ok, n} = Notes.create_status(b, %{"status" => "hi"})

      assert {:ok, _} = Notes.reblog(a, n.id)

      assert Repo.get_by!(Boost, account_id: a.id, note_id: n.id)

      assert Repo.exists?(
               from e in OutboxEvent, where: e.subject == "sns.outbox.announce.created"
             )
    end
  end

  describe "bookmark/2" do
    test "inserts Bookmark, no outbox event (local-only)" do
      a = create_account!("alice_bm")
      b = create_account!("bob_bm")
      {:ok, n} = Notes.create_status(b, %{"status" => "hi"})

      assert {:ok, _} = Notes.bookmark(a, n.id)
      assert Repo.get_by!(Bookmark, account_id: a.id, note_id: n.id)

      refute Repo.exists?(
               from e in OutboxEvent,
                 where:
                   like(e.subject, "sns.outbox.bookmark.%") and
                     e.aggregate_id == ^to_string(n.id)
             )
    end
  end

  describe "pin/2" do
    test "owner can pin + emits sns.outbox.add.created" do
      a = create_account!("alice_pin")
      {:ok, n} = Notes.create_status(a, %{"status" => "pinnable"})

      assert {:ok, _} = Notes.pin(a, n.id)
      assert Repo.get_by!(PinnedNote, account_id: a.id, note_id: n.id)

      assert Repo.exists?(
               from e in OutboxEvent, where: e.subject == "sns.outbox.add.created"
             )
    end

    test "non-owner → :forbidden" do
      a = create_account!("alice_pin_perm")
      b = create_account!("bob_pin_perm")
      {:ok, n} = Notes.create_status(a, %{"status" => "alice's"})

      assert {:error, :forbidden} = Notes.pin(b, n.id)
    end
  end

  describe "unpin/2" do
    test "emits sns.outbox.remove.created" do
      a = create_account!("alice_unpin")
      {:ok, n} = Notes.create_status(a, %{"status" => "p"})
      {:ok, _} = Notes.pin(a, n.id)

      assert {:ok, _} = Notes.unpin(a, n.id)
      refute Repo.get_by(PinnedNote, account_id: a.id, note_id: n.id)

      assert Repo.exists?(
               from e in OutboxEvent, where: e.subject == "sns.outbox.remove.created"
             )
    end
  end

  describe "counts_for_notes/1 + viewer_flags_many/2" do
    test "computes batched counts and per-note viewer flags" do
      a = create_account!("alice_counts")
      b = create_account!("bob_counts")
      {:ok, n1} = Notes.create_status(b, %{"status" => "1"})
      {:ok, n2} = Notes.create_status(b, %{"status" => "2"})

      {:ok, _} = Notes.favourite(a, n1.id)
      {:ok, _} = Notes.reblog(a, n1.id)
      {:ok, _} = Notes.bookmark(a, n2.id)

      counts = Notes.counts_for_notes([n1.id, n2.id])
      assert counts[n1.id].favourites == 1
      assert counts[n1.id].reblogs == 1
      assert counts[n2.id].favourites == 0

      flags = Notes.viewer_flags_many(a.id, [n1.id, n2.id])
      assert flags[n1.id].favourited == true
      assert flags[n1.id].reblogged == true
      assert flags[n2.id].bookmarked == true
      assert flags[n2.id].favourited == false
    end
  end

  describe "list_bookmarks/2 and list_favourites/2" do
    test "returns viewer's bookmarked notes newest-first" do
      a = create_account!("alice_list_bm")
      b = create_account!("bob_list_bm")
      {:ok, n1} = Notes.create_status(b, %{"status" => "1"})
      {:ok, n2} = Notes.create_status(b, %{"status" => "2"})

      {:ok, _} = Notes.bookmark(a, n1.id)
      {:ok, _} = Notes.bookmark(a, n2.id)

      list = Notes.list_bookmarks(a, limit: 50)
      ids = Enum.map(list, & &1.id)

      # Most recent bookmark first
      assert hd(ids) == n2.id
    end

    test "list_favourites returns only favourited (⭐) notes" do
      a = create_account!("alice_list_fav")
      b = create_account!("bob_list_fav")
      {:ok, n1} = Notes.create_status(b, %{"status" => "1"})
      {:ok, _n2} = Notes.create_status(b, %{"status" => "2"})

      {:ok, _} = Notes.favourite(a, n1.id)

      list = Notes.list_favourites(a, limit: 50)
      assert Enum.map(list, & &1.id) == [n1.id]
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end
end
