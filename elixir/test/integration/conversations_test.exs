# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.ConversationsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.{Conversations, Notes}
  alias SukhiFedi.Schema.{Account, ConversationParticipant, Note}

  describe "list/2" do
    test "returns the latest DM note per conversation, excluding the viewer from accounts" do
      alice = create_account!("alice_conv")
      bob = create_account!("bob_conv")
      carol = create_account!("carol_conv")

      # Alice <-> Bob conversation
      cid_ab = "https://example.test/contexts/ab"
      add_participant!(cid_ab, alice.id)
      add_participant!(cid_ab, bob.id)
      _n1 = insert_note!(alice.id, "hi bob", cid_ab)
      n2 = insert_note!(bob.id, "hey alice", cid_ab)

      # Alice + Carol conversation
      cid_ac = "https://example.test/contexts/ac"
      add_participant!(cid_ac, alice.id)
      add_participant!(cid_ac, carol.id)
      n3 = insert_note!(carol.id, "hello!", cid_ac)

      result = Conversations.list(alice.id)
      assert length(result) == 2

      # The conversation `id` is now the viewer's participant row (a
      # number), so identify each thread by its last status instead.
      [first, second] = result
      # Newest note's conversation comes first (n3 was inserted after n2 → carol).
      assert first.last_status.id == n3.id
      assert second.last_status.id == n2.id

      ab = Enum.find(result, &(&1.last_status.conversation_ap_id == cid_ab))
      assert ab.last_status.id == n2.id
      assert is_integer(ab.id)
      # Alice is the viewer — she should NOT be in the accounts list.
      assert [%{id: bob_id}] = ab.accounts
      assert bob_id == bob.id

      ac = Enum.find(result, &(&1.last_status.conversation_ap_id == cid_ac))
      assert ac.last_status.id == n3.id
      assert [%{id: carol_id}] = ac.accounts
      assert carol_id == carol.id
    end

    test "empty when the viewer participates in nothing" do
      alice = create_account!("alice_empty_conv")
      assert Conversations.list(alice.id) == []
    end

    test "a sent DM is read for the sender and unread for the recipient" do
      alice = create_account!("alice_cv_a")
      bob = create_account!("bob_cv_a")

      {:ok, note} =
        Notes.create_status(alice, %{"status" => "@bob_cv_a hey", "visibility" => "direct"})

      [a_convo] = Conversations.list(alice.id)
      assert a_convo.unread == false
      assert a_convo.last_status.id == note.id
      assert [%{username: "bob_cv_a"}] = a_convo.accounts

      [b_convo] = Conversations.list(bob.id)
      assert b_convo.unread == true
      assert [%{username: "alice_cv_a"}] = b_convo.accounts

      # Per-account id: each side sees a different id for the same thread.
      assert a_convo.id != b_convo.id
    end

    test "last_status carries in_reply_to_id" do
      alice = create_account!("alice_cv_ir")
      bob = create_account!("bob_cv_ir")

      {:ok, parent} =
        Notes.create_status(alice, %{"status" => "@bob_cv_ir hi", "visibility" => "direct"})

      {:ok, reply} =
        Notes.create_status(bob, %{
          "status" => "@alice_cv_ir hey",
          "visibility" => "direct",
          "in_reply_to_id" => to_string(parent.id)
        })

      [convo] = Conversations.list(alice.id)
      assert convo.last_status.id == reply.id

      # Mastodon's Conversation holds a *full* Status. `GET /api/v1/statuses/:id`
      # fills these through `Read.with_refs/2`; the conversations path used to
      # skip it, so a client saw the same note with a null `in_reply_to_id`
      # depending on which endpoint it came from.
      assert convo.last_status.in_reply_to_id == parent.id
      assert convo.last_status.in_reply_to_account_id == alice.id
    end
  end

  describe "statuses/3" do
    test "returns the conversation's notes newest-first, chain or no chain" do
      alice = create_account!("alice_cv_s")
      bob = create_account!("bob_cv_s")

      cid = "https://example.test/contexts/statuses"
      add_participant!(cid, alice.id)
      add_participant!(cid, bob.id)

      n1 = insert_note!(alice.id, "one", cid)
      n2 = insert_note!(bob.id, "two", cid)
      # Never replied to anything — the old getContext walk would miss it,
      # but it belongs to the conversation, so it comes back.
      n3 = insert_note!(alice.id, "three", cid)

      [a_convo] = Conversations.list(alice.id)
      assert {:ok, notes} = Conversations.statuses(alice.id, a_convo.id)
      assert Enum.map(notes, & &1.id) == [n3.id, n2.id, n1.id]
    end

    test "pages with max_id and limit" do
      alice = create_account!("alice_cv_sp")
      bob = create_account!("bob_cv_sp")

      cid = "https://example.test/contexts/paged"
      add_participant!(cid, alice.id)
      add_participant!(cid, bob.id)

      notes = for i <- 1..5, do: insert_note!(alice.id, "m#{i}", cid)
      [n1, n2, n3, n4, n5] = notes

      [a_convo] = Conversations.list(alice.id)

      assert {:ok, page1} = Conversations.statuses(alice.id, a_convo.id, limit: 2)
      assert Enum.map(page1, & &1.id) == [n5.id, n4.id]

      assert {:ok, page2} = Conversations.statuses(alice.id, a_convo.id, limit: 2, max_id: n4.id)
      assert Enum.map(page2, & &1.id) == [n3.id, n2.id]

      assert {:ok, page3} = Conversations.statuses(alice.id, a_convo.id, limit: 2, max_id: n2.id)
      assert Enum.map(page3, & &1.id) == [n1.id]
    end

    test "won't read someone else's conversation" do
      alice = create_account!("alice_cv_sx")
      bob = create_account!("bob_cv_sx")
      carol = create_account!("carol_cv_sx")

      cid = "https://example.test/contexts/private"
      add_participant!(cid, alice.id)
      add_participant!(cid, bob.id)
      insert_note!(alice.id, "just between us", cid)

      [a_convo] = Conversations.list(alice.id)

      # Carol is not in the thread, so Alice's row does not exist for her.
      assert {:error, :not_found} = Conversations.statuses(carol.id, a_convo.id)
      # Bob is in the thread, but Alice's row is still not his to read.
      assert {:error, :not_found} = Conversations.statuses(bob.id, a_convo.id)
      # Bob reads it through his own row.
      [b_convo] = Conversations.list(bob.id)
      assert {:ok, [%{content: "just between us"}]} = Conversations.statuses(bob.id, b_convo.id)
    end

    test "a conversation row that doesn't exist is not_found" do
      alice = create_account!("alice_cv_sn")
      assert {:error, :not_found} = Conversations.statuses(alice.id, 999_999_999)
    end

    test "notes carry in_reply_to_id" do
      alice = create_account!("alice_cv_si")
      bob = create_account!("bob_cv_si")

      {:ok, parent} =
        Notes.create_status(alice, %{"status" => "@bob_cv_si hi", "visibility" => "direct"})

      {:ok, reply} =
        Notes.create_status(bob, %{
          "status" => "@alice_cv_si hey",
          "visibility" => "direct",
          "in_reply_to_id" => to_string(parent.id)
        })

      [a_convo] = Conversations.list(alice.id)
      assert {:ok, notes} = Conversations.statuses(alice.id, a_convo.id)
      assert Enum.map(notes, & &1.id) == [reply.id, parent.id]
      assert hd(notes).in_reply_to_id == parent.id
    end
  end

  describe "mark_read/2" do
    test "clears the viewer's unread flag" do
      alice = create_account!("alice_cv_r")
      bob = create_account!("bob_cv_r")

      {:ok, _} =
        Notes.create_status(alice, %{"status" => "@bob_cv_r ping", "visibility" => "direct"})

      [b_convo] = Conversations.list(bob.id)
      assert b_convo.unread == true

      assert {:ok, cleared} = Conversations.mark_read(bob.id, b_convo.id)
      assert cleared.unread == false
      assert [%{unread: false}] = Conversations.list(bob.id)
    end

    test "won't clear another account's conversation" do
      alice = create_account!("alice_cv_x")
      bob = create_account!("bob_cv_x")

      {:ok, _} =
        Notes.create_status(alice, %{"status" => "@bob_cv_x yo", "visibility" => "direct"})

      [b_convo] = Conversations.list(bob.id)

      assert {:error, :not_found} = Conversations.mark_read(alice.id, b_convo.id)
      assert [%{unread: true}] = Conversations.list(bob.id)
    end
  end

  describe "fanout_entries/1" do
    test "one viewer-relative entry per local participant" do
      alice = create_account!("alice_cv_f")
      bob = create_account!("bob_cv_f")

      {:ok, note} =
        Notes.create_status(alice, %{"status" => "@bob_cv_f stream me", "visibility" => "direct"})

      entries = Conversations.fanout_entries(note.conversation_ap_id)
      assert length(entries) == 2

      by_account = Map.new(entries, &{&1.account_id, &1.entry})

      alice_entry = by_account[alice.id]
      assert alice_entry.unread == false
      assert [%{username: "bob_cv_f"}] = alice_entry.accounts
      assert alice_entry.last_status.id == note.id

      bob_entry = by_account[bob.id]
      assert bob_entry.unread == true
      assert [%{username: "alice_cv_f"}] = bob_entry.accounts
    end

    test "every entry's last_status carries in_reply_to_id" do
      # The streamed `conversation` payload goes to the same Mastodon clients
      # as the fetched one, so it has to be the same shape.
      alice = create_account!("alice_cv_fr")
      bob = create_account!("bob_cv_fr")

      {:ok, parent} =
        Notes.create_status(alice, %{"status" => "@bob_cv_fr hi", "visibility" => "direct"})

      {:ok, reply} =
        Notes.create_status(bob, %{
          "status" => "@alice_cv_fr hey",
          "visibility" => "direct",
          "in_reply_to_id" => to_string(parent.id)
        })

      entries = Conversations.fanout_entries(reply.conversation_ap_id)
      assert length(entries) == 2

      for %{entry: entry} <- entries do
        assert entry.last_status.id == reply.id
        assert entry.last_status.in_reply_to_id == parent.id
      end
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end

  defp add_participant!(cid, account_id) do
    %ConversationParticipant{}
    |> ConversationParticipant.changeset(%{
      conversation_ap_id: cid,
      account_id: account_id
    })
    |> Repo.insert!()
  end

  defp insert_note!(account_id, content, conversation_ap_id) do
    %Note{
      account_id: account_id,
      content: content,
      visibility: "direct",
      conversation_ap_id: conversation_ap_id
    }
    |> Repo.insert!()
  end
end
