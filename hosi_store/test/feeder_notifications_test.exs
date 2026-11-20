# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule FeederNotificationsTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv
  @moduletag :needs_pg

  alias SukhiHosi.{Accounts, Actors, Feeder, Follows, Ingest, Notes, Notifications, Pg}

  setup do
    {db, _dir} = TestDb.open()
    pg = SpikePg
    Pg.reset!(pg)

    %{db: db, pg: pg, alice: Actors.create_local(db, "alice"), bob: Actors.create_local(db, "bob")}
  end

  describe "feeder" do
    test "each line enters Postgres once, with sukhi's subjects; the next round has nothing", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      :ok = Notes.like(c.db, n, c.bob)

      assert [%{kind: "Create"}, %{kind: "Like"}] = Feeder.run_once(c.pg, c.db, "a")
      assert [] = Feeder.run_once(c.pg, c.db, "a")

      assert ["sns.outbox.note.created", "sns.outbox.like.created"] = c.pg |> Pg.outbox_rows() |> Enum.map(& &1.subject)

      :ok = Notes.unlike(c.db, n, c.bob)
      assert [%{kind: "Undo"}] = Feeder.run_once(c.pg, c.db, "a")
      assert 3 = length(Pg.outbox_rows(c.pg))
    end

    test "a round that dies leaves nothing in Postgres, and the next round takes the same lines", c do
      {:ok, _} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")

      assert_raise RuntimeError, "dies", fn ->
        Feeder.run_once(c.pg, c.db, "a", after_insert: fn _ -> raise "dies" end)
      end

      assert [] = Pg.outbox_rows(c.pg)
      assert [%{kind: "Create"}] = Feeder.run_once(c.pg, c.db, "a")
      assert [_] = Pg.outbox_rows(c.pg)
    end

    @tag :concurrent_pg
    test "two feeders of one name do not take the same line twice", c do
      # the cursor's row exists beforehand: on a brand-new row the first INSERT would make the second feeder wait, and hide what FOR UPDATE does
      Postgrex.query!(c.pg, "INSERT INTO hosi_feeder_cursor (name) VALUES ('a') ON CONFLICT DO NOTHING", [])
      for i <- 1..6, do: {:ok, _} = Notes.post(c.db, c.alice, "https://x/n/#{i}", "p#{i}")

      taken =
        1..2
        |> Task.async_stream(fn _ -> Feeder.run_once(c.pg, c.db, "a", limit: 3, after_insert: fn _ -> Process.sleep(300) end) end, timeout: 30_000)
        |> Enum.flat_map(fn {:ok, lines} -> lines end)

      rest = Feeder.run_once(c.pg, c.db, "a")
      assert 6 = length(taken ++ rest)
      assert 6 = length(Enum.uniq(Enum.map(taken ++ rest, & &1.id)))
      assert 6 = length(Pg.outbox_rows(c.pg))
    end

    test "if the cursor is lost, the unique source id still keeps a line from entering twice", c do
      {:ok, _} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      Feeder.run_once(c.pg, c.db, "a")
      Postgrex.query!(c.pg, "UPDATE hosi_feeder_cursor SET at = 0", [])

      Feeder.run_once(c.pg, c.db, "a")
      assert [_] = Pg.outbox_rows(c.pg)
    end

    test "an erased account's lines are not delivered if the feeder had not taken them (the order matters)", c do
      {:ok, _} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      {:ok, _} = Accounts.erase(c.db, c.alice)
      assert [] = Feeder.run_once(c.pg, c.db, "a")
    end
  end

  describe "notifications" do
    test "a like tells the author, in the same write; liking your own post tells no one", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      :ok = Notes.like(c.db, n, c.bob)
      :ok = Notes.like(c.db, n, c.alice)

      assert [%{type: :like, from: from, note: ^n}] = Notifications.list(c.db, c.alice)
      assert from == c.bob
      assert [] = Notifications.list(c.db, c.bob)
    end

    test "a like that is refused (already) tells no second time", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      :ok = Notes.like(c.db, n, c.bob)
      :already = Notes.like(c.db, n, c.bob)
      assert [_] = Notifications.list(c.db, c.alice)
    end

    test "unlike takes it away; liking again tells again", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      :ok = Notes.like(c.db, n, c.bob)
      :ok = Notes.unlike(c.db, n, c.bob)
      assert [] = Notifications.list(c.db, c.alice)
      :ok = Notes.like(c.db, n, c.bob)
      assert [_] = Notifications.list(c.db, c.alice)
    end

    test "newest first, and paged by id", c do
      ns = for i <- 1..5, do: elem(Notes.post(c.db, c.alice, "https://x/n/#{i}", "p#{i}"), 1)
      fans = for i <- 1..5, do: Actors.create_local(c.db, "fan#{i}")
      for {n, f} <- Enum.zip(ns, fans), do: :ok = Notes.like(c.db, n, f)

      [first, second | _] = Notifications.list(c.db, c.alice, limit: 2)
      assert first.id > second.id
      assert first.note == List.last(ns)

      older = Notifications.list(c.db, c.alice, before: second.id, limit: 10)
      assert length(older) == 3
      assert Enum.all?(older, &(&1.id < second.id))
    end

    test "only the recipient can dismiss; clear takes all of theirs and no one else's", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      {:ok, m} = Notes.post(c.db, c.bob, "https://x/n/2", "hi")
      :ok = Notes.like(c.db, n, c.bob)
      :ok = Notes.like(c.db, m, c.alice)
      [%{id: id}] = Notifications.list(c.db, c.alice)

      assert :not_found = Notifications.dismiss(c.db, c.bob, id)
      assert :ok = Notifications.dismiss(c.db, c.alice, id)
      assert [] = Notifications.list(c.db, c.alice)

      assert 1 = Notifications.clear(c.db, c.bob)
      assert [] = Notifications.list(c.db, c.bob)
    end

    test "erasing an account takes the notifications it had and the ones it caused", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      {:ok, m} = Notes.post(c.db, c.bob, "https://x/n/2", "hi")
      :ok = Notes.like(c.db, n, c.bob)
      :ok = Notes.like(c.db, m, c.alice)

      {:ok, _} = Accounts.erase(c.db, c.alice)
      assert [] = Notifications.list(c.db, c.bob)
      assert [] = Notifications.list(c.db, c.alice)
    end

    test "a follow request tells the one asked; saying yes turns it into a follow", c do
      :ok = Follows.follow(c.db, c.bob, c.alice)
      assert [%{type: :follow_request, from: from, note: nil}] = Notifications.list(c.db, c.alice)
      assert from == c.bob

      assert :ok = Follows.accept(c.db, c.bob, c.alice)
      assert [%{type: :follow}] = Notifications.list(c.db, c.alice)
      assert :not_pending = Follows.accept(c.db, c.bob, c.alice)
      assert [_] = Notifications.list(c.db, c.alice)
    end

    test "a follow that needs no yes tells as a follow; following again is refused and tells once", c do
      :ok = Follows.follow(c.db, c.bob, c.alice, state: :accepted)
      :already = Follows.follow(c.db, c.bob, c.alice, state: :accepted)
      assert [%{type: :follow}] = Notifications.list(c.db, c.alice)
    end

    test "one person following two people tells each of them; taking one back leaves the other's", c do
      carol = Actors.create_local(c.db, "carol")
      :ok = Follows.follow(c.db, c.bob, c.alice, state: :accepted)
      :ok = Follows.follow(c.db, c.bob, carol, state: :accepted)
      assert [%{type: :follow}] = Notifications.list(c.db, c.alice)
      assert [%{type: :follow}] = Notifications.list(c.db, carol)

      :ok = Follows.unfollow(c.db, c.bob, c.alice)
      assert [] = Notifications.list(c.db, c.alice)
      assert [%{type: :follow}] = Notifications.list(c.db, carol)
    end

    test "unfollow takes the notification away, whether it was a request or a follow; following again tells again", c do
      :ok = Follows.follow(c.db, c.bob, c.alice)
      :ok = Follows.unfollow(c.db, c.bob, c.alice)
      assert [] = Notifications.list(c.db, c.alice)

      :ok = Follows.follow(c.db, c.bob, c.alice, state: :accepted)
      :ok = Follows.unfollow(c.db, c.bob, c.alice)
      assert [] = Notifications.list(c.db, c.alice)

      :ok = Follows.follow(c.db, c.bob, c.alice)
      assert [%{type: :follow_request}] = Notifications.list(c.db, c.alice)
    end

    test "following oneself, or someone who is not an account here, tells no one", c do
      :ok = Follows.follow(c.db, c.alice, c.alice, state: :accepted)
      assert [] = Notifications.list(c.db, c.alice)

      remote = c.db |> Hosi.write(SukhiHosi.Actors.remote_ops(1, "https://far.test/users/zed")) |> then(fn {:ok, %{temps: [[1, id]]}} -> id end)
      :ok = Follows.follow(c.db, c.alice, remote, state: :accepted)
      assert [] = Notifications.list(c.db, remote)
    end

    test "a boost tells the author, as a reblog; boosting twice, or your own post, tells no more", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      :ok = Notes.boost(c.db, n, c.bob)
      :already = Notes.boost(c.db, n, c.bob)
      {:ok, mine} = Notes.post(c.db, c.bob, "https://x/n/2", "mine")
      :ok = Notes.boost(c.db, mine, c.bob)

      assert [%{type: :reblog, note: ^n}] = Notifications.list(c.db, c.alice)
      assert [] = Notifications.list(c.db, c.bob)
    end

    test "a like and a boost of the same post by the same person are two notifications", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      :ok = Notes.like(c.db, n, c.bob)
      :ok = Notes.boost(c.db, n, c.bob)
      assert [:like, :reblog] = c.db |> Notifications.list(c.alice) |> Enum.map(& &1.type) |> Enum.sort()
    end

    test "erasing the one who boosted takes their notification too", c do
      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hello")
      :ok = Notes.boost(c.db, n, c.bob)
      {:ok, _} = Accounts.erase(c.db, c.bob)
      assert [] = Notifications.list(c.db, c.alice)
    end

    test "a post tells the accounts here that it mentions; not its author, not twice, not a remote one", c do
      {:ok, remote} = Ingest.object(c.db, %{id: "https://far.test/p/0", actor: "https://far.test/users/zed", html: "hi"})
      zed = Actors.find(c.db, "https://far.test/users/zed")
      assert remote

      {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", "hey @bob @alice @zed", mentions: [c.bob, c.bob, c.alice, zed])

      assert [%{type: :mention, note: ^n, from: from}] = Notifications.list(c.db, c.bob)
      assert from == c.alice
      assert [] = Notifications.list(c.db, c.alice)
      assert [] = Notifications.list(c.db, zed)
    end

    test "two mentioned, two told, in the one write; a refused post tells no one", c do
      carol = Actors.create_local(c.db, "carol")
      {:ok, _} = Notes.post(c.db, c.alice, "https://x/n/1", "a", mentions: [c.bob, carol])
      assert [_] = Notifications.list(c.db, c.bob)
      assert [_] = Notifications.list(c.db, carol)

      assert {:error, :duplicate} = Notes.post(c.db, c.alice, "https://x/n/1", "again", mentions: [c.bob, carol])
      assert [_] = Notifications.list(c.db, c.bob)
    end

    test "a remote post that mentions someone here tells them, from the remote account", c do
      post = %{id: "https://far.test/p/1", actor: "https://far.test/users/zed", html: "hi @alice"}
      {:ok, n} = Ingest.object(c.db, post, mentions: [c.alice])
      zed = Actors.find(c.db, "https://far.test/users/zed")

      assert [%{type: :mention, note: ^n, from: from}] = Notifications.list(c.db, c.alice)
      assert from == zed
    end

    test "when the post is erased with its author, the mention goes with it", c do
      {:ok, _} = Notes.post(c.db, c.alice, "https://x/n/1", "hey", mentions: [c.bob])
      {:ok, _} = Accounts.erase(c.db, c.alice)
      assert [] = Notifications.list(c.db, c.bob)
    end

    test "sweep keeps an old remote post that mentions someone here, and takes one that does not", c do
      now = Notifications |> then(fn _ -> SukhiHosi.Store.now_us() end)
      old = now - 20 * 86_400 * 1_000_000
      plain = %{id: "https://far.test/p/1", actor: "https://far.test/users/zed", html: "plain"}
      about = %{id: "https://far.test/p/2", actor: "https://far.test/users/zed", html: "about alice"}
      {:ok, _} = Ingest.object(c.db, plain, published: old)
      {:ok, _} = Ingest.object(c.db, about, published: old, mentions: [c.alice])

      assert {:ok, %{kept: %{local_touch: 1}, swept: 1}} = SukhiHosi.Sweep.run(c.db, now: now, dry_run: true)
    end
  end
end
