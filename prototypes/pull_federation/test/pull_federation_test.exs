# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederationTest do
  use ExUnit.Case, async: true

  alias PullFederation.{Cursors, Etag, Origin, Puller, Sim}

  @a "https://a.example/users/alice"
  @b "https://a.example/users/bob"

  # a made-up token, for tests that never talk to an origin
  defp t(_key, n), do: "o.fake#{n}"

  # the real token of the nth event under `key` at origin `o`
  defp tok(o, key, n),
    do: o.log |> Map.fetch!(key) |> Enum.reverse() |> Enum.at(n - 1) |> Map.fetch!(:etag)

  defp note(id, vis \\ :public), do: %{type: :create, id: id, visibility: vis}

  defp setup_pair do
    origin =
      Origin.new()
      |> Origin.follow("b.example", @a)
      |> Origin.follow("b.example", @b)

    puller = Puller.new() |> Puller.follow("a.example", @a) |> Puller.follow("a.example", @b)
    {origin, puller}
  end

  describe "Cursors" do
    test "changed/2: opaque tokens count as news when they differ" do
      assert %{"b" => "o.y"} ==
               Cursors.changed(%{"a" => "o.x", "b" => "o.z"}, %{"a" => "o.x", "b" => "o.y"})

      assert %{"c" => "o.1"} == Cursors.changed(%{}, %{"c" => "o.1"})
    end

    test "changed/2: ordered tokens only count when ahead; a stale one is ignored" do
      assert %{"a" => "s.5"} == Cursors.changed(%{"a" => "s.4"}, %{"a" => "s.5"})
      assert %{} == Cursors.changed(%{"a" => "s.5"}, %{"a" => "s.4"})
      assert %{} == Cursors.changed(%{"a" => "s.5"}, %{"a" => "s.5"})
    end

    test "changed/2: mixing kinds falls back to equality" do
      assert %{"a" => "o.x"} == Cursors.changed(%{"a" => "s.5"}, %{"a" => "o.x"})
    end

    test "merge/2 never moves an ordered cursor backwards" do
      assert %{"a" => "s.5"} == Cursors.merge(%{"a" => "s.5"}, %{"a" => "s.4"})
      assert %{"a" => "s.6"} == Cursors.merge(%{"a" => "s.5"}, %{"a" => "s.6"})
      assert %{"a" => "o.new"} == Cursors.merge(%{"a" => "o.old"}, %{"a" => "o.new"})
    end

    test "parse/1 rejects garbage" do
      assert {:ok, _} = Cursors.parse(%{"a" => "o.tok"})
      assert {:ok, _} = Cursors.parse(%{"a" => "s.12"})
      assert :error = Cursors.parse(%{"a" => -1})
      assert :error = Cursors.parse(%{"a" => "tok"})
      assert :error = Cursors.parse(%{"a" => "s.-1"})
      assert :error = Cursors.parse(%{"a" => "s.x"})
      assert :error = Cursors.parse(%{"a" => "o." <> String.duplicate("x", 63)})
      assert :error = Cursors.parse(%{1 => "o.x"})
      assert :error = Cursors.parse("nope")
    end
  end

  describe "etag" do
    test "opaque tokens are fixed length, random, and say nothing about the count" do
      assert byte_size(Etag.opaque()) == 18
      assert Etag.opaque() != Etag.opaque()
    end

    test "public index tokens are the sequence; followers tokens are not" do
      {o, _} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("p1"))
      {o, _} = Origin.publish(o, @a, note("p2"))
      {o, _} = Origin.publish(o, @a, note("f1", :followers))
      assert Origin.etag(o, @a) == "s.2"
      assert "o." <> _ = Origin.etag(o, @a <> "#followers")
    end

    test "two origins with the same followers history issue different tokens" do
      {o1, _} = Origin.publish(Origin.new(), @a, note("f", :followers))
      {o2, _} = Origin.publish(Origin.new(), @a, note("f", :followers))
      assert Origin.etag(o1, @a <> "#followers") != Origin.etag(o2, @a <> "#followers")
    end

    test "compare/2" do
      assert :lt = Etag.compare("s.1", "s.2")
      assert :gt = Etag.compare("s.10", "s.9")
      assert :eq = Etag.compare("o.x", "o.x")
      assert :unordered = Etag.compare("o.x", "o.y")
      assert :unordered = Etag.compare("s.1", "o.y")
    end
  end

  describe "origin" do
    test "direct messages stay push-only and burn no seq" do
      {o, {:pull, 1}} = Origin.publish(Origin.new(), @a, note("n1"))
      {o, :push_only} = Origin.publish(o, @a, note("dm", :direct))
      {_, {:pull, 2}} = Origin.publish(o, @a, note("n2"))
    end

    test "public and followers-only have separate sequences" do
      {o, _} = setup_pair()
      {o, {:pull, 1}} = Origin.publish(o, @a, note("p1"))
      {o, {:pull, 1}} = Origin.publish(o, @a, note("f1", :followers))
      {o, {:pull, 2}} = Origin.publish(o, @a, note("p2", :unlisted))
      {_, [{"b.example", announced}]} = Origin.due_notifications(o, 0)

      assert announced == %{
               @a => tok(o, @a, 2),
               (@a <> "#followers") => tok(o, @a <> "#followers", 1)
             }
    end

    test "notifications are coalesced within the quiet window" do
      {o, _} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("1"))
      {o, [{"b.example", first}]} = Origin.due_notifications(o, 0)
      assert first == %{@a => tok(o, @a, 1)}

      {o, _} = Origin.publish(o, @a, note("2"))
      {o, _} = Origin.publish(o, @a, note("3"))
      assert {o, []} = Origin.due_notifications(o, 1_000)
      assert {_, [{"b.example", later}]} = Origin.due_notifications(o, 3_000)
      assert later == %{@a => tok(o, @a, 3)}
    end

    test "declines when all stream slots are taken" do
      {o, _} = setup_pair()
      o = %{o | max_streams: 1}
      {:ok, o, _, _} = Origin.open_stream(o, "b.example", %{}, 0)
      assert {:error, {:busy, 5_000}} = Origin.open_stream(o, "b.example", %{}, 0)

      assert {:ok, _, _, _} =
               o |> Origin.close_stream() |> Origin.open_stream("b.example", %{}, 0)
    end

    test "a domain never receives actors it does not follow" do
      {o, _} = setup_pair()
      o = Origin.follow(o, "c.example", "https://a.example/users/carol")
      {o, _} = Origin.publish(o, "https://a.example/users/carol", note("c1"))
      {:ok, _, events, announced} = Origin.open_stream(o, "b.example", %{}, 0)
      assert events == []
      assert announced == %{}
    end
  end

  describe "puller" do
    test "step 3: equal state is a no-op, behind state is planned" do
      {_, p} = setup_pair()
      assert {p, :planned} = Puller.notify(p, "a.example", %{@a => t(@a, 1)}, 0)
      assert {:pull, "a.example", %{}} = Puller.next_pull(p, 0, false)
    end

    test "unfollowed actors in a notification are ignored" do
      {_, p} = setup_pair()

      assert {_, :up_to_date} =
               Puller.notify(p, "a.example", %{"https://x/users/z" => "o.tok"}, 0)
    end

    test "notification floor per origin" do
      {_, p} = setup_pair()
      {p, :planned} = Puller.notify(p, "a.example", %{@a => t(@a, 1)}, 0)
      assert {_, :rate_limited} = Puller.notify(p, "a.example", %{@a => t(@a, 2)}, 500)
      assert {_, :planned} = Puller.notify(p, "a.example", %{@a => t(@a, 2)}, 1_000)
    end

    test "pool is bounded; known origins still merge" do
      p = Puller.new(max_pending: 1) |> Puller.follow("o1", "x") |> Puller.follow("o2", "y")
      {p, :planned} = Puller.notify(p, "o1", %{"x" => "o.t1"}, 0)
      assert {_, :pool_full} = Puller.notify(p, "o2", %{"y" => "o.t1"}, 0)
      assert {_, :planned} = Puller.notify(p, "o1", %{"x" => "o.t2"}, 2_000)
    end

    test "step 4: busy postpones" do
      {_, p} = setup_pair()
      {p, :planned} = Puller.notify(p, "a.example", %{@a => t(@a, 1)}, 0)
      assert :postponed = Puller.next_pull(p, 0, true)
      assert {:pull, _, _} = Puller.next_pull(p, 0, false)
    end

    test "decline backs off exponentially with jitter and honours retry-after" do
      {_, p} = setup_pair()
      {p, :planned} = Puller.notify(p, "a.example", %{@a => t(@a, 1)}, 0)
      j = fn max -> max end
      p = Puller.finish_pull(p, "a.example", {:error, {:busy, 5_000}}, 0, j)
      assert :idle = Puller.next_pull(p, 7_499, false)
      assert {:pull, _, _} = Puller.next_pull(p, 7_500, false)
      p = Puller.finish_pull(p, "a.example", {:error, {:busy, 5_000}}, 7_500, j)
      assert p.not_before["a.example"] == 7_500 + 10_000 + 5_000
    end

    test "invalid signatures are dropped and counted" do
      p = Puller.new(verify: fn %{id: id} -> if id == "bad", do: :error, else: :ok end)
      p = Puller.apply_activity(p, note("bad"), 0)
      p = Puller.apply_activity(p, note("good"), 0)
      assert p.rejected == 1
      assert Map.keys(p.store) == ["good"]
    end
  end

  describe "end to end" do
    test "notify -> pull -> converge; second round is idle" do
      {o, p} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("1"))
      {o, _} = Origin.publish(o, @a, note("2"))
      {o, _} = Origin.publish(o, @b, note("3"))
      {o, _} = Origin.publish(o, @a, note("dm", :direct))

      {o, p} = Sim.round(o, "b.example", p, now: 0)
      assert Map.keys(p.store) |> Enum.sort() == ["1", "2", "3"]
      assert p.cursors["a.example"] == %{@a => tok(o, @a, 2), @b => tok(o, @b, 1)}
      assert o.active_streams == 0

      {_, p2} = Sim.round(o, "b.example", p, now: 10_000)
      assert p2 == p
    end

    test "followers-only items are pulled through their own cursor" do
      {o, p} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("p1"))
      {o, _} = Origin.publish(o, @a, note("f1", :followers))
      {_, p} = Sim.round(o, "b.example", p, now: 0)
      assert Map.keys(p.store) |> Enum.sort() == ["f1", "p1"]

      assert p.cursors["a.example"] == %{
               @a => tok(o, @a, 1),
               (@a <> "#followers") => tok(o, @a <> "#followers", 1)
             }
    end

    test "busy B postpones, then catches up in one stream" do
      {o, p} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("1"))
      {o, p} = Sim.round(o, "b.example", p, now: 0, busy?: true)
      assert p.store == %{}
      {o, _} = Origin.publish(o, @a, note("2"))
      {_, p} = Sim.round(o, "b.example", p, now: 4_000)
      assert Map.keys(p.store) |> Enum.sort() == ["1", "2"]
    end

    test "busy A declines; B retries later and converges" do
      {o, p} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("1"))
      {o, p} = Sim.round(%{o | max_streams: 0}, "b.example", p, now: 0)
      assert p.store == %{}
      {_, p} = Sim.round(%{o | max_streams: 1}, "b.example", p, now: 20_000)
      assert Map.keys(p.store) == ["1"]
    end

    test "Delete pushed before the pulled Create wins; both ways is idempotent" do
      {o, p} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("1"))
      p = Puller.apply_activity(p, %{type: :delete, object: "1"}, 0)
      {_, p} = Sim.round(o, "b.example", p, now: 0)
      assert p.store == %{}

      p = Puller.apply_activity(p, note("2"), 0) |> Puller.apply_activity(note("2"), 0)
      assert map_size(p.store) == 1
    end

    test "recovery broadcast spreads domains by jitter" do
      {o, _} = setup_pair()
      o = Origin.follow(o, "c.example", @a)
      out = Origin.recovered(o, fn d -> byte_size(d) * 100 end)
      assert [{_, "b.example", _}, {_, "c.example", _}] = out
    end
  end

  describe "snapshots" do
    alias PullFederation.Snapshot

    test "sccache-style path and bucket from the actor uri" do
      <<a::binary-size(2), b::binary-size(2), _::binary>> = h = Snapshot.hash(@a)
      assert Snapshot.path(@a) == "#{a}/#{b}/#{h}"
      assert Snapshot.bucket(@a) == a
      assert Snapshot.bucket_path(a) == "#{a}/_index"
      assert byte_size(h) == 64
    end

    defp big_pair(n) do
      actors = for i <- 1..n, do: "https://a.example/users/u#{i}"
      o = Enum.reduce(actors, Origin.new(inline_max: 2), &Origin.follow(&2, "b.example", &1))
      p = Enum.reduce(actors, Puller.new(), &Puller.follow(&2, "a.example", &1))
      {o, p, actors}
    end

    test "few changes travel inline, many become bucket versions" do
      {o, _p, [u1, u2, u3 | _]} = big_pair(10)
      {o2, _} = Origin.publish(o, u1, note("1"))
      assert {_, [{"b.example", %{^u1 => token}}]} = Origin.due_notifications(o2, 0)
      assert token == tok(o2, u1, 1)

      o3 = Enum.reduce([u1, u2, u3], o, fn u, acc -> elem(Origin.publish(acc, u, note(u)), 0) end)
      assert {_, [{"b.example", {:buckets, versions, %{}}}]} = Origin.due_notifications(o3, 0)
      assert map_size(versions) in 1..3
      assert Enum.all?(Map.keys(versions), &(byte_size(&1) == 2))
    end

    test "actors nobody follows remotely never bump a bucket" do
      {o, _} = Origin.publish(Origin.new(), "https://a.example/users/lonely", note("1"))
      assert o.bucket_versions == %{}
    end

    test "followers-only never enters a snapshot" do
      {o, _p, [u1 | _]} = big_pair(3)
      {o, _} = Origin.publish(o, u1, note("f", :followers))
      assert o.bucket_versions == %{}

      for bucket <- Map.keys(o.bucket_versions) do
        assert Origin.bucket_doc(o, bucket).entries == %{}
      end
    end

    test "end to end through bucket snapshots" do
      {o, p, actors} = big_pair(10)
      o = Enum.reduce(actors, o, fn u, acc -> elem(Origin.publish(acc, u, note(u)), 0) end)
      assert {_, [{_, {:buckets, _, _}}]} = Origin.due_notifications(o, 0)

      {o, p} = Sim.round(o, "b.example", p, now: 0)
      assert Map.keys(p.store) |> Enum.sort() == Enum.sort(actors)
      assert p.wanted["a.example"] == %{}
      {_, p2} = Sim.round(o, "b.example", p, now: 10_000)
      assert p2 == p
    end

    test "a bucket the receiver has no followed actor in is not fetched" do
      {o, p, [u1 | _]} = big_pair(1)

      other =
        Enum.find(
          for(i <- 1..500, do: "https://x/#{i}"),
          &(Snapshot.bucket(&1) != Snapshot.bucket(u1))
        )

      {p, :invalid} = Puller.notify(p, "a.example", {:buckets, %{"zz" => -1}, %{}}, 0)

      {p, _} =
        Puller.notify(p, "a.example", {:buckets, %{Snapshot.bucket(other) => 1}, %{}}, 2_000)

      assert Puller.wanted_buckets(p, "a.example") == []
      _ = o
    end
  end

  describe "etag semantics" do
    test "only actors whose token changed are served, with their new tokens" do
      {o, _} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("a1"))
      {o, _} = Origin.publish(o, @b, note("b1"))
      {o, _} = Origin.publish(o, @b, note("b2"))

      {:ok, _, events, announced} =
        Origin.open_stream(o, "b.example", %{@a => tok(o, @a, 1)}, 0)

      assert Enum.map(events, & &1.activity.id) == ["b1", "b2"]
      assert announced == %{@a => tok(o, @a, 1), @b => tok(o, @b, 2)}
    end

    test "a token the origin does not know triggers a replay, which is idempotent" do
      {o, p} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("a1"))
      {o, _} = Origin.publish(o, @a, note("a2"))
      {:ok, o, events, _} = Origin.open_stream(o, "b.example", %{@a => "forged-or-old"}, 0)
      assert Enum.map(events, & &1.activity.id) == ["a1", "a2"]
      assert o.resyncs == 1

      p = Enum.reduce(events ++ events, p, &Puller.apply_activity(&2, &1.activity, 0))
      assert map_size(p.store) == 2
    end

    test "a stale ordered notification (public index) is ignored without a pull" do
      {o, p} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("a1"))
      {o, _} = Origin.publish(o, @a, note("a2"))
      {o, p} = Sim.round(o, "b.example", p, now: 0)
      assert p.cursors["a.example"][@a] == "s.2"

      assert {p2, :up_to_date} = Puller.notify(p, "a.example", %{@a => tok(o, @a, 1)}, 5_000)
      assert p2.pending == %{}
    end

    test "a stale opaque notification (followers index) costs one empty pull and then settles" do
      fkey = @a <> "#followers"
      {o, p} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("f1", :followers))
      {o, _} = Origin.publish(o, @a, note("f2", :followers))
      {o, p} = Sim.round(o, "b.example", p, now: 0)
      assert p.cursors["a.example"][fkey] == tok(o, fkey, 2)

      # a late copy of the older notification: different opaque token, so B pulls
      {p, :planned} = Puller.notify(p, "a.example", %{fkey => tok(o, fkey, 1)}, 5_000)
      p = Puller.begin_pull(p, "a.example")

      {:ok, _o, events, announced} =
        Origin.open_stream(o, "b.example", p.cursors["a.example"], 5_000)

      assert events == []
      p = Puller.finish_pull(p, "a.example", {:ok, events, announced}, 5_000, fn _ -> 0 end)
      assert p.pending == %{}
      assert p.cursors["a.example"][fkey] == tok(o, fkey, 2)
    end

    test "an ordered cursor is answered exactly, with no replay" do
      {o, _} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("a1"))
      {o, _} = Origin.publish(o, @a, note("a2"))
      {o, _} = Origin.publish(o, @a, note("a3"))
      {:ok, o, events, _} = Origin.open_stream(o, "b.example", %{@a => "s.1"}, 0)
      assert Enum.map(events, & &1.activity.id) == ["a2", "a3"]
      assert o.resyncs == 0
    end

    test "news that arrives while a pull is in flight is not lost" do
      {o, p} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("a1"))
      {p, :planned} = Puller.notify(p, "a.example", %{@a => tok(o, @a, 1)}, 0)
      p = Puller.begin_pull(p, "a.example")
      {:ok, o, events, announced} = Origin.open_stream(o, "b.example", %{}, 0)

      # a1 was just served; a2 is published and announced before the stream finishes
      {o2, _} = Origin.publish(o, @a, note("a2"))
      {p, :planned} = Puller.notify(p, "a.example", %{@a => tok(o2, @a, 2)}, 1_500)
      p = Puller.finish_pull(p, "a.example", {:ok, events, announced}, 2_000, fn _ -> 0 end)
      assert p.pending == %{"a.example" => %{@a => tok(o2, @a, 2)}}
    end
  end
end
