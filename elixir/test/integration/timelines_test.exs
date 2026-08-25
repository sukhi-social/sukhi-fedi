# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.TimelinesTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.{Lists, Notes, Social, Timelines}
  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Schema.{Account, Follow, Note}

  describe "home/2 with circles" do
    test "an exclusive circle's members leave home but stay in the circle feed" do
      alice = create_account!("alice_home")
      bob = create_account!("bob_home")

      # alice follows bob, both have a note → home shows both
      {:ok, _} = Social.request_follow(alice, bob.id)
      {:ok, _} = Notes.create_status(alice, %{"status" => "from alice"})
      {:ok, _} = Notes.create_status(bob, %{"status" => "from bob"})

      home_before = Timelines.home(alice)
      assert Enum.any?(home_before, &(Map.get(&1, :account_id) == bob.id))
      assert Enum.any?(home_before, &(Map.get(&1, :account_id) == alice.id))

      # move bob into an *exclusive* circle (follow is untouched)
      {:ok, circle} = Lists.create(alice.id, %{title: "quiet", exclusive: true})
      :ok = Lists.add_accounts(alice.id, circle.id, [bob.id])

      # home drops bob, keeps alice's own note
      home_after = Timelines.home(alice)
      refute Enum.any?(home_after, &(Map.get(&1, :account_id) == bob.id))
      assert Enum.any?(home_after, &(Map.get(&1, :account_id) == alice.id))

      # but bob is still readable in the circle's own feed
      {:ok, feed} = Lists.timeline(alice.id, circle.id)
      assert Enum.any?(feed, &(&1.account_id == bob.id))
    end

    test "a circle member's reply to a post on this server still reaches home" do
      alice = create_account!("alice_rep")
      bob = create_account!("bob_rep")

      {:ok, _} = Social.request_follow(alice, bob.id)
      {:ok, circle} = Lists.create(alice.id, %{title: "quiet", exclusive: true})
      :ok = Lists.add_accounts(alice.id, circle.id, [bob.id])

      domain = SukhiFedi.Config.domain!()

      # a plain post from bob → hidden (he's in an exclusive circle)
      {:ok, soliloquy} = Notes.create_status(bob, %{"status" => "thinking out loud"})
      # bob replying to a post on this server (≈ to alice) → still reaches home
      reply =
        %Note{}
        |> Note.changeset(%{
          account_id: bob.id,
          content: "@alice hey",
          visibility: "public",
          in_reply_to_ap_id: "https://#{domain}/users/alice_rep/statuses/1"
        })
        |> Repo.insert!()

      home = Timelines.home(alice)
      ids = Enum.map(home, &Map.get(&1, :id))

      assert reply.id in ids
      refute soliloquy.id in ids
    end
  end

  describe "home/2 exclude_self" do
    # 「友達が言ったこと」の面。自分の投稿が自分の面に居るのは、
    # 反応の付かない自分の行を自分で何度も見ることでもある。
    test "自分の投稿とブーストが落ちて、友達のは残る" do
      alice = create_account!("alice_xs")
      bob = create_account!("bob_xs")

      {:ok, _} = Social.request_follow(alice, bob.id)
      {:ok, mine} = Notes.create_status(alice, %{"status" => "わたしの"})
      {:ok, theirs} = Notes.create_status(bob, %{"status" => "ともだちの"})

      with_self = Timelines.home(alice, limit: 50) |> Enum.map(& &1.id)
      assert mine.id in with_self
      assert theirs.id in with_self

      without = Timelines.home(alice, limit: 50, exclude_self: true) |> Enum.map(& &1.id)
      refute mine.id in without
      assert theirs.id in without
    end

    test "自分のブーストも落ちる" do
      alice = create_account!("alice_xsb")
      bob = create_account!("bob_xsb")
      carol = create_account!("carol_xsb")

      {:ok, _} = Social.request_follow(alice, bob.id)
      {:ok, note} = Notes.create_status(carol, %{"status" => "よそのひと"})

      # alice が自分でブーストしたものは、alice の面には出ない。
      {:ok, _} = Notes.reblog(alice, note.id)
      {:ok, _} = Notes.create_status(bob, %{"status" => "ともだちの"})

      rows = Timelines.home(alice, limit: 50, exclude_self: true)
      refute Enum.any?(rows, fn r -> Map.get(r, :__boost__) && r.account.id == alice.id end)
      assert Enum.any?(rows, &(Map.get(&1, :account_id) == bob.id))
    end
  end

  describe "parents_for_notes/1" do
    # 平らに並べる面が返信へ添える一行。話す板と友デコで同じ道を通る。
    test "返信は親の一行を持ち、親を持たない投稿は地図に載らない" do
      alice = create_account!("alice_par")

      {:ok, parent} = Notes.create_status(alice, %{"status" => "この板の名前どうしよう"})
      {:ok, reply} = Notes.create_status(alice, %{"status" => "ナタデコでいいと思う", "in_reply_to_id" => parent.id})

      map = Notes.parents_for_notes([parent.id, reply.id])

      refute Map.has_key?(map, parent.id)
      assert %{id: pid, excerpt: excerpt, author: %{acct: "alice_par"}} = map[reply.id]
      assert pid == parent.id
      assert excerpt =~ "この板の名前どうしよう"
    end

    test "抜粋は素の一行 ── HTML も改行も畳んである" do
      alice = create_account!("alice_par2")

      {:ok, parent} = Notes.create_status(alice, %{"status" => "**ふとい**字と\n\n改行"})
      {:ok, reply} = Notes.create_status(alice, %{"status" => "つづき", "in_reply_to_id" => parent.id})

      %{excerpt: excerpt} = Notes.parents_for_notes([reply.id])[reply.id]
      refute excerpt =~ "<"
      refute excerpt =~ "\n"
      assert excerpt =~ "ふとい"
    end
  end

  describe "home/2 filters" do
    test "hide_sensitive drops sensitive and CW posts" do
      alice = create_account!("alice_filt")
      {:ok, plain} = Notes.create_status(alice, %{"status" => "plain"})

      sens =
        %Note{}
        |> Note.changeset(%{
          account_id: alice.id,
          content: "nsfw",
          visibility: "public",
          sensitive: true
        })
        |> Repo.insert!()

      cw =
        %Note{}
        |> Note.changeset(%{
          account_id: alice.id,
          content: "spoiler",
          visibility: "public",
          cw: "warning"
        })
        |> Repo.insert!()

      all_ids = alice |> Timelines.home() |> Enum.map(&Map.get(&1, :id))
      assert sens.id in all_ids
      assert cw.id in all_ids

      kept = alice |> Timelines.home(hide_sensitive: true) |> Enum.map(&Map.get(&1, :id))
      assert plain.id in kept
      refute sens.id in kept
      refute cw.id in kept
    end

    test "a non-exclusive list's hide_sensitive filter narrows its members in home" do
      alice = create_account!("alice_pl")
      bob = create_account!("bob_pl")

      {:ok, _} = Social.request_follow(alice, bob.id)

      {:ok, list} =
        Lists.create(alice.id, %{title: "filtered", exclusive: false, filter_hide_sensitive: true})

      :ok = Lists.add_accounts(alice.id, list.id, [bob.id])

      {:ok, plain} = Notes.create_status(bob, %{"status" => "ok"})

      sens =
        %Note{}
        |> Note.changeset(%{
          account_id: bob.id,
          content: "nsfw",
          visibility: "public",
          sensitive: true
        })
        |> Repo.insert!()

      ids = alice |> Timelines.home() |> Enum.map(&Map.get(&1, :id))
      # 通常投稿は出る。sensitive は per-list filter(hide_sensitive)で消える。
      assert plain.id in ids
      refute sens.id in ids
    end

    test "a hide-replies list drops members' replies from home, keeps top-level posts" do
      alice = create_account!("alice_hr")
      bob = create_account!("bob_hr")
      {:ok, _} = Social.request_follow(alice, bob.id)

      {:ok, list} =
        Lists.create(alice.id, %{title: "no replies", exclusive: false, filter_replies: "hide"})

      :ok = Lists.add_accounts(alice.id, list.id, [bob.id])

      {:ok, top} = Notes.create_status(bob, %{"status" => "top level"})

      reply =
        %Note{}
        |> Note.changeset(%{
          account_id: bob.id,
          content: "a reply",
          visibility: "public",
          in_reply_to_ap_id: "https://remote.example/users/x/statuses/1"
        })
        |> Repo.insert!()

      ids = alice |> Timelines.home() |> Enum.map(&Map.get(&1, :id))
      assert top.id in ids
      refute reply.id in ids
    end

    test "a replies-to-me list keeps replies to a post here, drops replies elsewhere" do
      alice = create_account!("alice_rtm")
      bob = create_account!("bob_rtm")
      {:ok, _} = Social.request_follow(alice, bob.id)

      {:ok, list} =
        Lists.create(alice.id, %{title: "to me", exclusive: false, filter_replies: "to_me"})

      :ok = Lists.add_accounts(alice.id, list.id, [bob.id])

      domain = SukhiFedi.Config.domain!()
      {:ok, top} = Notes.create_status(bob, %{"status" => "top level"})

      to_here =
        %Note{}
        |> Note.changeset(%{
          account_id: bob.id,
          content: "@alice hi",
          visibility: "public",
          in_reply_to_ap_id: "https://#{domain}/users/alice_rtm/statuses/1"
        })
        |> Repo.insert!()

      elsewhere =
        %Note{}
        |> Note.changeset(%{
          account_id: bob.id,
          content: "talking to someone else",
          visibility: "public",
          in_reply_to_ap_id: "https://remote.example/users/x/statuses/1"
        })
        |> Repo.insert!()

      ids = alice |> Timelines.home() |> Enum.map(&Map.get(&1, :id))
      assert top.id in ids
      assert to_here.id in ids
      refute elsewhere.id in ids
    end

    test "a keyword list admits only members' posts matching the keyword in content" do
      alice = create_account!("alice_kw")
      bob = create_account!("bob_kw")
      {:ok, _} = Social.request_follow(alice, bob.id)

      {:ok, list} =
        Lists.create(alice.id, %{title: "garden", exclusive: false, filter_keyword: "garden"})

      :ok = Lists.add_accounts(alice.id, list.id, [bob.id])

      {:ok, match} = Notes.create_status(bob, %{"status" => "my garden today"})
      {:ok, miss} = Notes.create_status(bob, %{"status" => "hello world"})

      ids = alice |> Timelines.home() |> Enum.map(&Map.get(&1, :id))
      assert match.id in ids
      refute miss.id in ids
    end

    test "a keyword list with a leading # matches the hashtag" do
      alice = create_account!("alice_tag")
      bob = create_account!("bob_tag")
      {:ok, _} = Social.request_follow(alice, bob.id)

      {:ok, list} =
        Lists.create(alice.id, %{title: "cats", exclusive: false, filter_keyword: "#cats"})

      :ok = Lists.add_accounts(alice.id, list.id, [bob.id])

      {:ok, tagged} = Notes.create_status(bob, %{"status" => "look at my #cats"})
      {:ok, untagged} = Notes.create_status(bob, %{"status" => "a dog post"})

      ids = alice |> Timelines.home() |> Enum.map(&Map.get(&1, :id))
      assert tagged.id in ids
      refute untagged.id in ids
    end
  end

  describe "instance silence" do
    test "a silenced instance's notes are materialized but kept off home and public" do
      admin = create_account!("sil_admin")
      alice = create_account!("sil_alice")
      noisy = create_remote_account!("noisy", "loud.example")

      # alice follows the remote author, who posts → normally home + public
      Repo.insert!(%Follow{
        follower_uri: local_uri(alice.username),
        followee_id: noisy.id,
        state: "accepted"
      })

      note =
        %Note{}
        |> Note.changeset(%{
          account_id: noisy.id,
          content: "from a noisy place",
          visibility: "public",
          ap_id: "https://loud.example/users/noisy/statuses/1",
          domain: "loud.example"
        })
        |> Repo.insert!()

      home_before = alice |> Timelines.home() |> Enum.map(&Map.get(&1, :id))
      public_before = Timelines.public(local: false) |> Enum.map(& &1.id)
      assert note.id in home_before
      assert note.id in public_before

      # silence the instance → the note row stays (still in the DB) but leaves
      # both surfaces, for the follower and for the federated public TL
      {:ok, _} = Moderation.block_instance("loud.example", "silence", nil, admin.id)

      assert Repo.get(Note, note.id)
      refute note.id in (alice |> Timelines.home() |> Enum.map(&Map.get(&1, :id)))
      refute note.id in (Timelines.public(local: false) |> Enum.map(& &1.id))
    end
  end

  describe "bubble/1" do
    test "shows only public remote notes from allowed domains; excludes local and non-allowed" do
      admin = create_account!("bub_admin")
      local = create_account!("bub_local")
      friend = create_remote_account!("friend", "good.example")
      stranger = create_remote_account!("stranger", "other.example")

      # a local public note (never in the bubble — it's remote-only)
      {:ok, local_note} = Notes.create_status(local, %{"status" => "from home"})

      # a public note from a trusted neighbour (good.example)
      good =
        %Note{}
        |> Note.changeset(%{
          account_id: friend.id,
          content: "hi from next door",
          visibility: "public",
          ap_id: "https://good.example/users/friend/statuses/1",
          domain: "good.example"
        })
        |> Repo.insert!()

      # a followers-only note from the same trusted neighbour (not public)
      private =
        %Note{}
        |> Note.changeset(%{
          account_id: friend.id,
          content: "just for followers",
          visibility: "followers",
          ap_id: "https://good.example/users/friend/statuses/2",
          domain: "good.example"
        })
        |> Repo.insert!()

      # a public note from a non-allowed instance (other.example)
      outside =
        %Note{}
        |> Note.changeset(%{
          account_id: stranger.id,
          content: "from the firehose",
          visibility: "public",
          ap_id: "https://other.example/users/stranger/statuses/1",
          domain: "other.example"
        })
        |> Repo.insert!()

      # empty allow-set → empty bubble (curated, never the firehose)
      assert Timelines.bubble() == []

      # add good.example to the bubble allow-set
      {:ok, _} = Moderation.add_bubble_instance("good.example", admin.id)

      ids = Timelines.bubble() |> Enum.map(& &1.id)
      assert good.id in ids
      refute local_note.id in ids
      refute private.id in ids
      refute outside.id in ids
    end
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

  defp local_uri(username), do: "https://#{SukhiFedi.Config.domain!()}/users/#{username}"
end
