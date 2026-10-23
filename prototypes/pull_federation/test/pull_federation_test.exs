# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederationTest do
  use ExUnit.Case, async: true

  alias PullFederation.{Origin, Puller, Seq, Sim}

  @a "https://a.example/users/alice"
  @b "https://a.example/users/bob"

  defp note(id, vis \\ :public), do: %{type: :create, id: id, visibility: vis}

  defp setup_pair do
    origin =
      Origin.new()
      |> Origin.follow("b.example", @a)
      |> Origin.follow("b.example", @b)

    puller = Puller.new() |> Puller.follow("a.example", @a) |> Puller.follow("a.example", @b)
    {origin, puller}
  end

  describe "Seq" do
    test "behind/2 returns only actors that moved ahead" do
      assert %{"b" => 124} == Seq.behind(%{"a" => 123, "b" => 122}, %{"a" => 123, "b" => 124})
      assert %{"c" => 1} == Seq.behind(%{}, %{"c" => 1})
    end

    test "parse/1 rejects garbage" do
      assert :error = Seq.parse(%{"a" => -1})
      assert :error = Seq.parse(%{1 => 1})
      assert :error = Seq.parse("nope")
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
      assert announced == %{@a => 2, (@a <> "#followers") => 1}
    end

    test "notifications are coalesced within the quiet window" do
      {o, _} = setup_pair()
      {o, _} = Origin.publish(o, @a, note("1"))
      {o, [{"b.example", %{@a => 1}}]} = Origin.due_notifications(o, 0)

      {o, _} = Origin.publish(o, @a, note("2"))
      {o, _} = Origin.publish(o, @a, note("3"))
      assert {o, []} = Origin.due_notifications(o, 1_000)
      assert {_, [{"b.example", %{@a => 3}}]} = Origin.due_notifications(o, 3_000)
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
      assert {p, :planned} = Puller.notify(p, "a.example", %{@a => 1}, 0)
      assert {:pull, "a.example", %{}} = Puller.next_pull(p, 0, false)
    end

    test "unfollowed actors in a notification are ignored" do
      {_, p} = setup_pair()
      assert {_, :up_to_date} = Puller.notify(p, "a.example", %{"https://x/users/z" => 9}, 0)
    end

    test "notification floor per origin" do
      {_, p} = setup_pair()
      {p, :planned} = Puller.notify(p, "a.example", %{@a => 1}, 0)
      assert {_, :rate_limited} = Puller.notify(p, "a.example", %{@a => 2}, 500)
      assert {_, :planned} = Puller.notify(p, "a.example", %{@a => 2}, 1_000)
    end

    test "pool is bounded; known origins still merge" do
      p = Puller.new(max_pending: 1) |> Puller.follow("o1", "x") |> Puller.follow("o2", "y")
      {p, :planned} = Puller.notify(p, "o1", %{"x" => 1}, 0)
      assert {_, :pool_full} = Puller.notify(p, "o2", %{"y" => 1}, 0)
      assert {_, :planned} = Puller.notify(p, "o1", %{"x" => 2}, 2_000)
    end

    test "step 4: busy postpones" do
      {_, p} = setup_pair()
      {p, :planned} = Puller.notify(p, "a.example", %{@a => 1}, 0)
      assert :postponed = Puller.next_pull(p, 0, true)
      assert {:pull, _, _} = Puller.next_pull(p, 0, false)
    end

    test "decline backs off exponentially with jitter and honours retry-after" do
      {_, p} = setup_pair()
      {p, :planned} = Puller.notify(p, "a.example", %{@a => 1}, 0)
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
      assert p.cursors["a.example"] == %{@a => 2, @b => 1}
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
      assert p.cursors["a.example"] == %{@a => 1, (@a <> "#followers") => 1}
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
end
