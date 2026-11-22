# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule IngestSweepTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv

  alias SukhiHosi.{Accounts, Actors, Follows, Ingest, Notes, Outbox, Store, Sweep, Timeline}

  @day 86_400 * 1_000_000

  setup do
    {db, dir} = TestDb.open()
    %{db: db, dir: dir, alice: Actors.create_local(db, "alice"), bob: Actors.create_local(db, "bob"), now: Store.now_us()}
  end

  defp remote(db, n, age_days, now, opts \\ []) do
    post = %{id: "https://far.test/p/#{n}", actor: "https://far.test/users/zed", html: "far #{n}"}
    {:ok, id} = Ingest.object(db, post, [published: now - age_days * @day] ++ opts)
    id
  end

  # dtlv answers one call per process and cannot be read while it is written (hosigraph guide,
  # "Seen in testing"); this one asks that of it, so it runs on the JVM khana (HOSI_BACKEND=jvm).
  @tag :concurrent_read
  test "a remote post brings its actor; the same post again, or at once, is made once", %{db: db} do
    post = %{id: "https://far.test/p/1", actor: "https://far.test/users/zed", html: "hello from far"}
    assert {:ok, id} = Ingest.object(db, post)
    assert :already = Ingest.object(db, post)
    assert %{local?: false} = %{local?: false}
    assert Actors.find(db, "https://far.test/users/zed")

    other = %{id: "https://far.test/p/2", actor: "https://far.test/users/zed", html: "again"}

    results =
      1..10 |> Task.async_stream(fn _ -> Ingest.object(db, other) end, max_concurrency: 10) |> Enum.map(&elem(&1, 1))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == :already)) == 9

    actors = Store.rows(db, "[:find ?a :where [?a :actor/id \"https://far.test/users/zed\"]]")
    assert length(actors) == 1

    assert [%{id: ^id}] = Timeline.public(db) |> Enum.filter(&(&1.html == "hello from far"))
    assert Outbox.after_id(db, 0) == [], "a remote post is not ours to deliver"
  end

  test "a remote reply joins the thread of its parent", %{db: db, alice: a} do
    {:ok, root} = Notes.post(db, a, "https://x/alice/1", "root")
    reply = %{id: "https://far.test/p/9", actor: "https://far.test/users/zed", html: "reply"}
    {:ok, r} = Ingest.object(db, reply, in_reply_to_iri: "https://x/alice/1")
    assert Timeline.thread(db, r) |> Enum.map(& &1.html) == ["root", "reply"]
    assert Timeline.thread(db, root) |> Enum.map(& &1.html) == ["root", "reply"]
  end

  test "every reference in the schema is either a dependent or an edge: a new one forces a decision" do
    refs = for {attr, %{type: :ref}} <- Store.schema(), do: attr
    assert Enum.sort(refs) == Enum.sort(Sweep.dependents() ++ Sweep.edges())
  end

  test "sweep keeps what has a reason, takes the rest, and the bytes go", %{db: db, dir: dir, alice: a, bob: b, now: now} do
    old_plain = remote(db, 1, 20, now, tags: ["gone"])
    liked = remote(db, 2, 20, now)
    boosted = remote(db, 3, 20, now)
    young_thread_root = remote(db, 4, 20, now)
    {:ok, _young} = Ingest.object(db, %{id: "https://far.test/p/4b", actor: "https://far.test/users/zed", html: "young"}, published: now - 1 * @day, in_reply_to_iri: "https://far.test/p/4")
    local_thread_root = remote(db, 5, 20, now)
    {:ok, _mine} = Notes.post(db, a, "https://x/alice/r", "my reply", in_reply_to: local_thread_root)
    followed_ok = elem(Ingest.object(db, %{id: "https://friend.test/p/1", actor: "https://friend.test/users/f", html: "friend 20d"}, published: now - 20 * @day), 1)
    followed_old = elem(Ingest.object(db, %{id: "https://friend.test/p/2", actor: "https://friend.test/users/f", html: "friend 100d"}, published: now - 100 * @day), 1)
    {:ok, local_old} = Notes.post(db, a, "https://x/alice/old", "my old post", published: now - 400 * @day)

    :ok = Notes.like(db, liked, a)
    :ok = Notes.boost(db, boosted, b)
    :ok = Follows.follow(db, a, Actors.find(db, "https://friend.test/users/f"), state: :accepted)
    # a boost of a post that will be swept, by someone remote: a dependent that must go with it
    :ok = Notes.boost(db, old_plain, Actors.find(db, "https://far.test/users/zed"))

    boosts = fn -> db |> Store.rows("[:find ?b :where [?b :activity/type :Announce]]") |> length() end
    lines_about = fn id -> db |> Outbox.after_id(0, 1000) |> Enum.count(&(&1.note == id)) end
    assert boosts.() == 2
    assert lines_about.(old_plain) == 1

    assert {:ok, dry} = Sweep.run(db, now: now, dry_run: true)
    assert %{swept: 2, kept: %{local_touch: 2, local_thread: 1, young_thread: 2, followed: 1}} = dry
    assert Notes.get(db, old_plain).html == "far 1", "a dry run changes nothing"

    # the reasons overlap (root 5 is in a local thread and a young one); a post is kept if any holds
    assert {:ok, %{swept: 2}} = Sweep.run(db, now: now, ttl_followed_s: 90 * 86_400)

    gone = [old_plain, followed_old]
    kept = [liked, boosted, young_thread_root, local_thread_root, followed_ok, local_old]
    for id <- gone, do: assert(Notes.get(db, id).html == nil)
    for id <- kept, do: assert(Notes.get(db, id).html != nil)

    assert boosts.() == 1, "the boost of a swept post goes with it; the boost of a kept one stays"
    assert lines_about.(old_plain) == 0
    assert lines_about.(boosted) == 1
    assert {:ok, %{swept: 0}} = Sweep.run(db, now: now), "running again finds nothing more"

    Hosi.stop(db)
    bytes = for f <- Path.wildcard(Path.join(dir, "**"), match_dot: true), File.regular?(f), into: "", do: File.read!(f)
    refute bytes =~ "far 1"
    refute bytes =~ "friend 100d"
    assert bytes =~ "friend 20d"
  end

  test "erasing an account also takes its follows, boosts and posts' boosts", %{db: db, alice: a, bob: b} do
    {:ok, n} = Notes.post(db, a, "https://x/alice/1", "alice's")
    :ok = Follows.follow(db, b, a, state: :accepted)
    :ok = Notes.boost(db, n, b)
    {:ok, bn} = Notes.post(db, b, "https://x/bob/1", "bob's")
    :ok = Notes.boost(db, bn, a)

    assert [_, _] = Timeline.home(db, b) |> Enum.filter(&(&1.html in ["alice's", "bob's"]))

    {:ok, _} = Accounts.erase(db, a)

    assert Follows.followees(db, b) == []
    assert Store.rows(db, "[:find ?b :where [?b :activity/type :Announce]]") == []
    assert Enum.map(Timeline.home(db, b), & &1.html) == ["bob's"]
  end
end
