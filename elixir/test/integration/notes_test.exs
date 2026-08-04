# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.NotesTest do
  @moduledoc """
  End-to-end tests for `SukhiFedi.Notes` create_status / get_note /
  delete_note / context. Requires the test Postgres with core
  migrations applied.

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias SukhiFedi.{Notes, Timelines}
  alias SukhiFedi.Schema.{Account, ConversationParticipant, Follow, Media, Note, OutboxEvent}

  describe "create_status/2" do
    test "creates a Note + emits sns.outbox.note.created" do
      a = create_account!("alice_cs")

      assert {:ok, note} =
               Notes.create_status(a, %{"status" => "hello", "visibility" => "public"})

      assert note.content == "hello"
      assert note.visibility == "public"
      assert note.account_id == a.id

      ev =
        Repo.one!(
          from(e in OutboxEvent,
            where:
              e.subject == "sns.outbox.note.created" and e.aggregate_id == ^to_string(note.id)
          )
        )

      assert ev.payload["note_id"] == note.id
    end

    test "spoiler_text → cw, in_reply_to_id resolves to ap_id" do
      a = create_account!("alice_reply")

      {:ok, parent} = Notes.create_status(a, %{"status" => "first", "visibility" => "public"})

      _ = update_ap_id(parent, "https://x.example/notes/parent_42")

      {:ok, child} =
        Notes.create_status(a, %{
          "status" => "reply",
          "spoiler_text" => "cw text",
          "in_reply_to_id" => to_string(parent.id),
          "visibility" => "public"
        })

      assert child.cw == "cw text"
      assert child.in_reply_to_ap_id == "https://x.example/notes/parent_42"
    end

    test "reply to a LOCAL parent stores the parent's synthesized ap_id" do
      a = create_account!("alice_local_reply")

      # Parent is local: its `ap_id` is NULL (left as the schema default).
      {:ok, parent} = Notes.create_status(a, %{"status" => "first", "visibility" => "public"})
      assert is_nil(parent.ap_id)

      {:ok, child} =
        Notes.create_status(a, %{
          "status" => "reply",
          "in_reply_to_id" => to_string(parent.id),
          "visibility" => "public"
        })

      expected =
        "https://#{SukhiFedi.Config.domain!()}/users/#{a.username}/notes/#{parent.id}"

      # Not NULL — otherwise a local→local reply has no threading link.
      assert child.in_reply_to_ap_id == expected
      # …and the Mastodon Status view resolves it back to the parent.
      assert child.in_reply_to_id == parent.id
      assert child.in_reply_to_account_id == a.id
    end

    test "direct status with no resolvable mention → :dm_no_recipients" do
      a = create_account!("alice_dm")

      assert {:error, :dm_no_recipients} =
               Notes.create_status(a, %{
                 "status" => "secret, nobody home",
                 "visibility" => "direct"
               })
    end

    test "direct status to a local user → Note(direct) + participants, no federation" do
      alice = create_account!("alice_dm_send")
      bob = create_account!("bob_dm_recv")

      assert {:ok, note} =
               Notes.create_status(alice, %{
                 "status" => "@bob_dm_recv psst",
                 "visibility" => "direct"
               })

      assert note.visibility == "direct"

      # New thread → conversation_ap_id is the note's own synthesized AP id.
      expected_cid = "https://#{SukhiFedi.Config.domain!()}/users/alice_dm_send/notes/#{note.id}"
      assert note.conversation_ap_id == expected_cid

      # Both are participants; the sender is read, the recipient unread.
      assert %{unread: false} = participant(note.conversation_ap_id, alice.id)
      assert %{unread: true} = participant(note.conversation_ap_id, bob.id)

      # A purely local DM has nobody to federate to.
      refute Repo.exists?(
               from(e in OutboxEvent,
                 where:
                   e.subject == "sns.outbox.dm.created" and
                     e.aggregate_id == ^to_string(note.id)
               )
             )
    end

    test "direct status to a remote user → federates with conversation context" do
      alice = create_account!("alice_dm_fed")
      _bob = create_remote_account!("bob", "remote.example")

      assert {:ok, note} =
               Notes.create_status(alice, %{
                 "status" => "@bob@remote.example hi",
                 "visibility" => "direct"
               })

      ev =
        Repo.one!(
          from(e in OutboxEvent,
            where:
              e.subject == "sns.outbox.dm.created" and
                e.aggregate_id == ^to_string(note.id)
          )
        )

      assert "https://remote.example/users/bob" in ev.payload["recipient_actor_uris"]
      # The federated event carries the thread so the other side can thread.
      assert ev.payload["conversation_ap_id"] == note.conversation_ap_id
      assert is_binary(note.conversation_ap_id)
    end

    test "group direct status → one dm.created addressed to every remote participant, one conversation" do
      alice = create_account!("alice_group_dm")
      _bob = create_remote_account!("bob", "remote.one")
      _carol = create_remote_account!("carol", "remote.two")

      assert {:ok, note} =
               Notes.create_status(alice, %{
                 "status" => "@bob@remote.one @carol@remote.two huddle",
                 "visibility" => "direct"
               })

      # One Create(Note) event for the whole group — threading by
      # conversation, not one event per recipient.
      ev =
        Repo.one!(
          from(e in OutboxEvent,
            where:
              e.subject == "sns.outbox.dm.created" and
                e.aggregate_id == ^to_string(note.id)
          )
        )

      # Addressed to *each* participant: the audience the delivery node
      # hands the `dm` builder carries both, so neither server silently
      # drops the activity.
      assert "https://remote.one/users/bob" in ev.payload["recipient_actor_uris"]
      assert "https://remote.two/users/carol" in ev.payload["recipient_actor_uris"]

      # The group stays one thread.
      assert ev.payload["conversation_ap_id"] == note.conversation_ap_id
      assert is_binary(note.conversation_ap_id)
    end

    test "direct reply inherits the parent's conversation" do
      alice = create_account!("alice_dm_thread")
      _bob = create_account!("bob_dm_thread")

      {:ok, root} =
        Notes.create_status(alice, %{"status" => "@bob_dm_thread one", "visibility" => "direct"})

      {:ok, reply} =
        Notes.create_status(alice, %{
          "status" => "@bob_dm_thread two",
          "visibility" => "direct",
          "in_reply_to_id" => to_string(root.id)
        })

      assert reply.conversation_ap_id == root.conversation_ap_id
    end

    test "media_ids[] not owned by user → :media_not_owned" do
      a = create_account!("alice_media")
      b = create_account!("bob_media")

      m = create_media!(b)

      assert {:error, :media_not_owned} =
               Notes.create_status(a, %{
                 "status" => "x",
                 "media_ids" => [to_string(m.id)]
               })
    end

    test "media_ids[] owned by user — note has media after create" do
      a = create_account!("alice_owned")
      m = create_media!(a)

      assert {:ok, note} =
               Notes.create_status(a, %{
                 "status" => "with media",
                 "media_ids" => [to_string(m.id)]
               })

      reloaded = Repo.preload(Repo.get!(Note, note.id), :media)
      assert Enum.map(reloaded.media, & &1.id) == [m.id]
    end

    test "quote_id sets quote_of_ap_id + carries it in sns.outbox.note.created" do
      a = create_account!("alice_quote")
      {:ok, quoted} = Notes.create_status(a, %{"status" => "original", "visibility" => "public"})

      assert {:ok, note} =
               Notes.create_status(a, %{
                 "status" => "quoting that",
                 "visibility" => "public",
                 "quote_id" => to_string(quoted.id)
               })

      expected =
        "https://#{SukhiFedi.Config.domain!()}/users/alice_quote/notes/#{quoted.id}"

      assert note.quote_of_ap_id == expected

      ev =
        Repo.one!(
          from(e in OutboxEvent,
            where:
              e.subject == "sns.outbox.note.created" and
                e.aggregate_id == ^to_string(note.id)
          )
        )

      assert ev.payload["quote_of_ap_id"] == expected
    end
  end

  describe "get_note/1" do
    test "returns the note with assocs preloaded" do
      a = create_account!("alice_get")
      {:ok, note} = Notes.create_status(a, %{"status" => "x"})

      assert {:ok, fetched} = Notes.get_note(note.id)
      assert fetched.id == note.id
      assert fetched.account.id == a.id
    end

    test "unknown id → :not_found" do
      assert {:error, :not_found} = Notes.get_note(99_999_999)
    end
  end

  describe "delete_note/2" do
    test "owner can delete + emits sns.outbox.note.deleted" do
      a = create_account!("alice_del")
      {:ok, note} = Notes.create_status(a, %{"status" => "to be deleted"})

      assert {:ok, _} = Notes.delete_note(a, note.id)
      refute Repo.get(Note, note.id)

      ev =
        Repo.one!(
          from(e in OutboxEvent,
            where:
              e.subject == "sns.outbox.note.deleted" and e.aggregate_id == ^to_string(note.id)
          )
        )

      assert ev.payload["note_id"] == note.id
    end

    test "non-owner → :forbidden" do
      a = create_account!("alice_perm")
      b = create_account!("bob_perm")
      {:ok, note} = Notes.create_status(a, %{"status" => "private to a"})

      assert {:error, :forbidden} = Notes.delete_note(b, note.id)
      assert Repo.get(Note, note.id)
    end

    test "unknown id → :not_found" do
      a = create_account!("alice_404")
      assert {:error, :not_found} = Notes.delete_note(a, 99_999_999)
    end
  end

  describe "context/1" do
    test "returns ancestors and descendants" do
      a = create_account!("alice_ctx")

      {:ok, root} = Notes.create_status(a, %{"status" => "root"})
      _ = update_ap_id(root, "https://x.example/notes/root")

      {:ok, mid} =
        Notes.create_status(a, %{"status" => "mid", "in_reply_to_id" => to_string(root.id)})

      _ = update_ap_id(mid, "https://x.example/notes/mid")

      {:ok, leaf} =
        Notes.create_status(a, %{"status" => "leaf", "in_reply_to_id" => to_string(mid.id)})

      _ = update_ap_id(leaf, "https://x.example/notes/leaf")

      assert {:ok, %{ancestors: ancestors, descendants: descendants}} = Notes.context(mid.id)

      ancestor_ids = Enum.map(ancestors, & &1.id)
      descendant_ids = Enum.map(descendants, & &1.id)

      assert root.id in ancestor_ids
      assert leaf.id in descendant_ids
    end

    test "threads through a local parent and orders ancestors oldest-first" do
      alice = create_account!("alice_local_ctx")
      bob = create_remote_account!("bob_remote_ctx", "remote.example")

      # original (remote) <- mid (local, ap_id NULL) <- reply (remote).
      original =
        %Note{
          account_id: bob.id,
          content: "original",
          visibility: "public",
          ap_id: "https://remote.example/notes/ctx_root"
        }
        |> Repo.insert!()

      {:ok, mid} =
        Notes.create_status(alice, %{
          "status" => "local mid",
          "in_reply_to_id" => to_string(original.id)
        })

      mid_uri = "https://#{SukhiFedi.Config.domain!()}/users/#{alice.username}/notes/#{mid.id}"

      reply =
        %Note{
          account_id: bob.id,
          content: "remote reply",
          visibility: "public",
          ap_id: "https://remote.example/notes/ctx_reply",
          in_reply_to_ap_id: mid_uri
        }
        |> Repo.insert!()

      # Opening the reply surfaces the whole chain, oldest first — the
      # local mid (NULL ap_id) resolved by its synthesized URL.
      assert {:ok, %{ancestors: ancestors}} = Notes.context(reply.id)
      assert Enum.map(ancestors, & &1.id) == [original.id, mid.id]

      # Opening the local mid shows its remote child as a descendant.
      assert {:ok, %{descendants: descendants}} = Notes.context(mid.id)
      assert reply.id in Enum.map(descendants, & &1.id)
    end

    test "threads through a purely local chain (every note local: domain NULL)" do
      alice = create_account!("alice_all_local")

      {:ok, root} = Notes.create_status(alice, %{"status" => "root"})

      {:ok, mid} =
        Notes.create_status(alice, %{"status" => "mid", "in_reply_to_id" => to_string(root.id)})

      {:ok, leaf} =
        Notes.create_status(alice, %{"status" => "leaf", "in_reply_to_id" => to_string(mid.id)})

      # No remote ap_id anywhere: all three are local (domain NULL), even
      # though each now carries its own canonical ap_id.
      assert is_nil(Repo.get(Note, root.id).domain)

      assert {:ok, %{ancestors: ancestors, descendants: descendants}} = Notes.context(mid.id)
      assert Enum.map(ancestors, & &1.id) == [root.id]
      assert leaf.id in Enum.map(descendants, & &1.id)
    end
  end

  describe "visibility gating (C2)" do
    defp local_uri(username),
      do: "https://#{Application.get_env(:sukhi_fedi, :domain, "localhost:4000")}/users/#{username}"

    test "get_note/2 hides a followers-only note from non-followers and the public" do
      author = create_account!("vis_author")
      follower = create_account!("vis_follower")
      stranger = create_account!("vis_stranger")

      Repo.insert!(%Follow{
        follower_uri: local_uri(follower.username),
        followee_id: author.id,
        state: "accepted"
      })

      {:ok, note} =
        Notes.create_status(author, %{"status" => "followers only", "visibility" => "followers"})

      assert {:error, :not_found} = Notes.get_note(note.id, nil)
      assert {:error, :not_found} = Notes.get_note(note.id, stranger.id)
      assert {:ok, _} = Notes.get_note(note.id, author.id)
      assert {:ok, _} = Notes.get_note(note.id, follower.id)
    end

    test "get_note/2 hides a direct (DM) note from everyone but its participants" do
      alice = create_account!("vis_dm_alice")
      bob = create_account!("vis_dm_bob")
      mallory = create_account!("vis_dm_mallory")

      {:ok, dm} =
        Notes.create_status(alice, %{
          "status" => "@#{bob.username} hi",
          "visibility" => "direct"
        })

      assert {:error, :not_found} = Notes.get_note(dm.id, nil)
      assert {:error, :not_found} = Notes.get_note(dm.id, mallory.id)
      assert {:ok, _} = Notes.get_note(dm.id, alice.id)
      assert {:ok, _} = Notes.get_note(dm.id, bob.id)
    end

    test "favourite/2 refuses a followers-only note the caller can't see" do
      author = create_account!("vis_fav_author")
      stranger = create_account!("vis_fav_stranger")

      {:ok, note} =
        Notes.create_status(author, %{"status" => "secret", "visibility" => "followers"})

      assert {:error, :not_found} = Notes.favourite(stranger.id, note.id)
      assert {:ok, _} = Notes.favourite(author.id, note.id)
    end

    test "context/2 drops thread nodes the viewer may not see" do
      author = create_account!("vis_ctx_author")
      stranger = create_account!("vis_ctx_stranger")

      {:ok, root} =
        Notes.create_status(author, %{"status" => "root public", "visibility" => "public"})

      {:ok, _priv_reply} =
        Notes.create_status(author, %{
          "status" => "followers-only reply",
          "visibility" => "followers",
          "in_reply_to_id" => to_string(root.id)
        })

      assert {:ok, %{descendants: descendants}} = Notes.context(root.id, stranger.id)
      assert descendants == []

      assert {:ok, %{descendants: own}} = Notes.context(root.id, author.id)
      assert length(own) == 1
    end

    test "list_statuses hides followers-only/direct on a profile from strangers and the public" do
      author = create_account!("vis_ls_author")
      follower = create_account!("vis_ls_follower")
      stranger = create_account!("vis_ls_stranger")

      Repo.insert!(%Follow{
        follower_uri: local_uri(follower.username),
        followee_id: author.id,
        state: "accepted"
      })

      # Insert one note per visibility directly — exercises the list-level
      # filter regardless of which visibilities the local create path accepts.
      for v <- ["public", "unlisted", "followers", "direct"] do
        Repo.insert!(%Note{account_id: author.id, content: v, visibility: v})
      end

      vis = fn viewer_id ->
        SukhiFedi.Accounts.list_statuses(author.id, viewer_id: viewer_id)
        |> Enum.map(& &1.visibility)
        |> Enum.sort()
      end

      # Public/unauthenticated and strangers: only public + unlisted.
      assert vis.(nil) == ["public", "unlisted"]
      assert vis.(stranger.id) == ["public", "unlisted"]

      # An accepted follower additionally sees followers-only — never the DM.
      assert vis.(follower.id) == ["followers", "public", "unlisted"]

      # The owner sees their own followers-only too; a profile timeline never
      # lists direct messages (those live in conversations).
      assert vis.(author.id) == ["followers", "public", "unlisted"]
    end

    test "list_statuses interleaves the account's boosts as reblog rows" do
      booster = create_account!("boost_ls_booster")
      author = create_account!("boost_ls_author")

      {:ok, own} = Notes.create_status(booster, %{"status" => "my own post"})
      {:ok, theirs} = Notes.create_status(author, %{"status" => "someone else's post"})
      {:ok, _} = Notes.reblog(booster, theirs.id)

      rows = SukhiFedi.Accounts.list_statuses(booster.id, [])

      # Own note appears as a plain Note; the boost appears as a wrapper
      # carrying the boosted note — that's what renders as a reblog Status.
      assert own.id in Enum.map(rows, & &1.id)

      boost = Enum.find(rows, &Map.get(&1, :__boost__))
      assert boost
      assert boost.note.id == theirs.id
      assert boost.account.id == booster.id

      # exclude_reblogs drops the boost but keeps the own note.
      no_reblogs = SukhiFedi.Accounts.list_statuses(booster.id, exclude_reblogs: true)
      assert own.id in Enum.map(no_reblogs, & &1.id)
      refute Enum.any?(no_reblogs, &Map.get(&1, :__boost__))
    end
  end

  describe "block / mute enforcement (C2)" do
    test "Notifications.create is dropped when the recipient blocked the actor" do
      alice = create_account!("blk_notif_alice")
      bob = create_account!("blk_notif_bob")

      {:ok, _} = SukhiFedi.Addons.Moderation.block(alice.id, bob.id)

      assert {:ok, :blocked_skip} =
               SukhiFedi.Notifications.create(%{
                 account_id: alice.id,
                 from_account_id: bob.id,
                 type: "follow"
               })

      assert SukhiFedi.Notifications.list(alice.id, []) == []
    end

    test "home/2 excludes a muted account the viewer follows" do
      alice = create_account!("mute_home_alice")
      bob = create_account!("mute_home_bob")
      carol = create_account!("mute_home_carol")

      for followee <- [bob, carol] do
        Repo.insert!(%Follow{
          follower_uri: local_uri("mute_home_alice"),
          followee_id: followee.id,
          state: "accepted"
        })
      end

      {:ok, bob_note} = Notes.create_status(bob, %{"status" => "from bob"})
      {:ok, carol_note} = Notes.create_status(carol, %{"status" => "from carol"})

      {:ok, _} = SukhiFedi.Addons.Moderation.mute(alice.id, carol.id)

      ids = alice |> Timelines.home(limit: 50) |> Enum.map(& &1.id)

      assert bob_note.id in ids
      refute carol_note.id in ids
    end

    test "home/2 hides a muted author's post surfaced by a followed user's boost" do
      alice = create_account!("mute_boost_alice")
      bob = create_account!("mute_boost_bob")
      carol = create_account!("mute_boost_carol")
      dave = create_account!("mute_boost_dave")

      # alice follows only bob, the booster — not the authors he boosts.
      Repo.insert!(%Follow{
        follower_uri: local_uri("mute_boost_alice"),
        followee_id: bob.id,
        state: "accepted"
      })

      {:ok, carol_note} = Notes.create_status(carol, %{"status" => "from carol"})
      {:ok, dave_note} = Notes.create_status(dave, %{"status" => "from dave"})
      {:ok, _} = Notes.reblog(bob, carol_note.id)
      {:ok, _} = Notes.reblog(bob, dave_note.id)

      {:ok, _} = SukhiFedi.Addons.Moderation.mute(alice.id, carol.id)

      boosted_ids =
        alice
        |> Timelines.home(limit: 50)
        |> Enum.filter(&Map.get(&1, :__boost__))
        |> Enum.map(& &1.note.id)

      # bob's boost of dave's post still reaches home; his boost of the
      # muted carol's post does not.
      assert dave_note.id in boosted_ids
      refute carol_note.id in boosted_ids
    end
  end

  describe "Timelines" do
    test "public/1 returns only public notes, newest first" do
      a = create_account!("alice_tl_pub")

      {:ok, n1} = Notes.create_status(a, %{"status" => "public 1", "visibility" => "public"})

      {:ok, _f} =
        Notes.create_status(a, %{"status" => "followers only", "visibility" => "followers"})

      {:ok, n2} = Notes.create_status(a, %{"status" => "public 2", "visibility" => "public"})

      result = Timelines.public(limit: 50)
      ids = Enum.map(result, & &1.id)

      assert n2.id in ids
      assert n1.id in ids
    end

    test "home/2 returns viewer's notes + followed accounts' notes" do
      alice = create_account!("alice_tl_home")
      bob = create_account!("bob_tl_home")
      _carol = create_account!("carol_tl_home")

      domain = Application.get_env(:sukhi_fedi, :domain, "localhost:4000")
      alice_uri = "https://#{domain}/users/alice_tl_home"

      Repo.insert!(%Follow{
        follower_uri: alice_uri,
        followee_id: bob.id,
        state: "accepted"
      })

      {:ok, alice_note} = Notes.create_status(alice, %{"status" => "alice's"})
      {:ok, bob_note} = Notes.create_status(bob, %{"status" => "bob's"})

      result = Timelines.home(alice, limit: 50)
      ids = Enum.map(result, & &1.id)

      assert alice_note.id in ids
      assert bob_note.id in ids
    end
  end

  describe "with_refs/1" do
    test "resolves in_reply_to and quote to local rows + preloads quoted account" do
      author = create_account!("wr_author")
      replier = create_account!("wr_replier")

      parent = note!(author, "https://x.example/notes/p1", "parent")

      reply =
        note!(replier, "https://x.example/notes/r1", "reply", in_reply_to_ap_id: parent.ap_id)

      quoted = note!(author, "https://x.example/notes/q1", "quoted")

      quoting =
        note!(replier, "https://x.example/notes/qt1", "quoting", quote_of_ap_id: quoted.ap_id)

      [er, eq] = Notes.with_refs([reply, quoting])

      assert er.in_reply_to_id == parent.id
      assert er.in_reply_to_account_id == author.id
      assert er.quoted_note == nil

      assert eq.quoted_note.id == quoted.id
      # account is preloaded for the nested-Status render
      assert eq.quoted_note.account.username == "wr_author"
      assert eq.in_reply_to_id == nil
    end

    test "leaves refs nil when the referenced note isn't held locally" do
      replier = create_account!("wr_dangling")

      reply =
        note!(replier, "https://x.example/notes/d1", "orphan reply",
          in_reply_to_ap_id: "https://gone.example/notes/x"
        )

      [er] = Notes.with_refs([reply])
      assert er.in_reply_to_id == nil
      assert er.in_reply_to_account_id == nil
    end

    test "resolves a LOCAL parent / LOCAL quoted note (NULL ap_id, synthesized URL)" do
      author = create_account!("wr_local_author")
      replier = create_account!("wr_local_replier")

      # Local targets: ap_id NULL, referenced by their synthesized URL.
      {:ok, parent} = Notes.create_status(author, %{"status" => "local parent"})
      {:ok, quoted} = Notes.create_status(author, %{"status" => "local quoted"})

      base = "https://#{SukhiFedi.Config.domain!()}/users/#{author.username}/notes"
      parent_uri = "#{base}/#{parent.id}"
      quoted_uri = "#{base}/#{quoted.id}"

      reply = note!(replier, "https://x.example/notes/lr1", "reply", in_reply_to_ap_id: parent_uri)
      quoting = note!(replier, "https://x.example/notes/lq1", "quoting", quote_of_ap_id: quoted_uri)

      [er, eq] = Notes.with_refs([reply, quoting])

      assert er.in_reply_to_id == parent.id
      assert er.in_reply_to_account_id == author.id
      assert eq.quoted_note.id == quoted.id
      assert eq.quoted_note.account.username == "wr_local_author"
    end
  end

  describe "snowflake note ids" do
    test "new notes get a non-sequential, time-sortable id" do
      a = create_account!("snow_a")
      {:ok, n1} = Notes.create_status(a, %{"status" => "first"})
      {:ok, n2} = Notes.create_status(a, %{"status" => "second"})

      # Snowflake = (ms since 2024) << 16 — far above the old sequential
      # range, and increasing for later notes so id-based paging holds.
      assert n1.id > 1_000_000_000_000
      assert n2.id > n1.id
    end
  end

  defp note!(account, ap_id, content, extra \\ []) do
    %Note{content: content, visibility: "public", account_id: account.id, ap_id: ap_id}
    |> struct(Map.new(extra))
    |> Repo.insert!()
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end

  defp create_remote_account!(username, domain) do
    %Account{
      username: username,
      domain: domain,
      display_name: username,
      summary: "",
      actor_uri: "https://#{domain}/users/#{username}"
    }
    |> Repo.insert!()
  end

  defp participant(conversation_ap_id, account_id) do
    Repo.one(
      from(cp in ConversationParticipant,
        where: cp.conversation_ap_id == ^conversation_ap_id and cp.account_id == ^account_id,
        select: %{unread: cp.unread}
      )
    )
  end

  defp create_media!(account) do
    %Media{
      url: "https://x.example/m/#{:rand.uniform(10_000)}.png",
      type: "image",
      account_id: account.id
    }
    |> Repo.insert!()
  end

  describe "locality: notes.domain + persisted local ap_id" do
    test "changeset derives domain from the ap_id host" do
      import Ecto.Changeset
      ours = SukhiFedi.Config.domain!()

      remote = Note.changeset(%Note{}, %{content: "x", account_id: 1, ap_id: "https://other.example/notes/9"})
      assert get_field(remote, :domain) == "other.example"

      local = Note.changeset(%Note{}, %{content: "x", account_id: 1})
      assert get_field(local, :domain) == nil

      own = Note.changeset(%Note{}, %{content: "x", account_id: 1, ap_id: "https://#{ours}/users/u/notes/1"})
      assert get_field(own, :domain) == nil
    end

    test "create_status persists the canonical ap_id and stays local (domain nil)" do
      a = create_account!("alice_apid")
      {:ok, note} = Notes.create_status(a, %{"status" => "hi", "visibility" => "public"})

      reloaded = Repo.get!(Note, note.id)
      assert reloaded.domain == nil
      assert reloaded.ap_id == "https://#{SukhiFedi.Config.domain!()}/users/#{a.username}/notes/#{note.id}"
    end

    test "delete_note carries the ap_id (not nil) — the federation-of-deletes fix" do
      a = create_account!("alice_del")
      {:ok, note} = Notes.create_status(a, %{"status" => "bye", "visibility" => "public"})

      assert {:ok, _} = Notes.delete_note(a, note.id)

      ev =
        Repo.one!(
          from(e in OutboxEvent,
            where:
              e.subject == "sns.outbox.note.deleted" and e.aggregate_id == ^to_string(note.id)
          )
        )

      assert ev.payload["ap_id"] ==
               "https://#{SukhiFedi.Config.domain!()}/users/#{a.username}/notes/#{note.id}"
    end

    test "local_notes / remote_notes filter on domain, not ap_id" do
      a = create_account!("alice_loc")
      {:ok, created} = Notes.create_status(a, %{"status" => "local", "visibility" => "public"})
      local = Repo.get!(Note, created.id)

      {:ok, remote} =
        %Note{}
        |> Note.changeset(%{
          account_id: a.id,
          content: "remote",
          ap_id: "https://other.example/notes/7",
          visibility: "public"
        })
        |> Repo.insert()

      local_ids = Notes.local_notes() |> Repo.all() |> Enum.map(& &1.id)
      remote_ids = Notes.remote_notes() |> Repo.all() |> Enum.map(& &1.id)

      # the local note has an ap_id now, yet is still classified local
      assert local.ap_id != nil
      assert local.id in local_ids
      refute local.id in remote_ids
      assert remote.id in remote_ids
      refute remote.id in local_ids
    end
  end

  defp update_ap_id(%Note{id: id}, ap_id) do
    Repo.update_all(from(n in Note, where: n.id == ^id), set: [ap_id: ap_id])
  end
  describe "mention notifications for locally-written notes" do
    # These did not exist. `mention` rows were only ever created in
    # `AP.Instructions.Mirror` — the path a note takes coming in *from
    # another server* — so nothing written here notified anybody. A
    # conversation could run to a hundred messages with not one `mention`
    # behind it, which is why Web Push stayed silent with every part of it
    # working: the pipe was complete and nothing upstream fed it.

    defp mentions_for(account_id) do
      SukhiFedi.Repo.all(
        from n in SukhiFedi.Schema.Notification,
          where: n.account_id == ^account_id and n.type == "mention",
          select: n.note_id
      )
    end

    test "a DM notifies the person it names" do
      a = create_account!("m_sender")
      b = create_account!("m_target")

      {:ok, note} = Notes.create_status(a.id, %{"status" => "@m_target こんにちは", "visibility" => "direct"})

      assert mentions_for(b.id) == [note.id]
    end

    test "a public post naming someone notifies them too" do
      a = create_account!("m_sender2")
      b = create_account!("m_target2")

      {:ok, note} = Notes.create_status(a.id, %{"status" => "@m_target2 みてみて", "visibility" => "public"})

      assert mentions_for(b.id) == [note.id]
    end

    test "@name@our-own-domain counts as here" do
      a = create_account!("m_sender3")
      b = create_account!("m_target3")
      host = SukhiFedi.Config.domain!() |> String.split(":") |> hd()

      {:ok, note} =
        Notes.create_status(a.id, %{"status" => "@m_target3@#{host} やあ", "visibility" => "public"})

      assert mentions_for(b.id) == [note.id]
    end

    test "naming yourself does not notify you" do
      a = create_account!("m_self")
      {:ok, _} = Notes.create_status(a.id, %{"status" => "@m_self ひとりごと", "visibility" => "public"})
      assert mentions_for(a.id) == []
    end

    test "a name nobody here has is simply skipped" do
      a = create_account!("m_sender4")
      # No WebFinger, no fetch — a notification is only ever for someone
      # who lives here, so an unknown handle must not reach out anywhere.
      {:ok, _} = Notes.create_status(a.id, %{"status" => "@nobody_at_all やあ", "visibility" => "public"})
      assert true
    end

    test "the same person named twice is notified once" do
      a = create_account!("m_sender5")
      b = create_account!("m_target5")

      {:ok, note} =
        Notes.create_status(a.id, %{"status" => "@m_target5 と @m_target5", "visibility" => "public"})

      assert mentions_for(b.id) == [note.id]
    end
  end

end
