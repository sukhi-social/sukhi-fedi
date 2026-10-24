# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule ModeTest do
  use ExUnit.Case, async: true

  alias PullFederation.{Compare, Mode, Origin, Puller}

  @a "https://a.example/users/alice"

  defp note(id, vis \\ :public), do: %{type: :create, id: id, visibility: vis}

  defp post(m, d, t) do
    m = Mode.observe_post(m, d, t)
    Mode.mode(m, d, t)
  end

  describe "Mode" do
    test "a quiet domain stays on push" do
      {_m, modes} =
        Enum.reduce(0..9, {Mode.new(), []}, fn i, {m, acc} ->
          {m, mode} = post(m, "d", i * 10_000)
          {m, [mode | acc]}
        end)

      assert Enum.all?(modes, &(&1 == :push))
    end

    test "two posts inside one window are enough to switch, without waiting for the average" do
      {m, :push} = post(Mode.new(), "d", 0)
      assert {_, :pull} = post(m, "d", 500)
    end

    test "the rate is per domain" do
      {m, _} = post(Mode.new(), "busy", 0)
      {m, :pull} = post(m, "busy", 100)
      assert {_, :push} = post(m, "quiet", 200)
    end

    test "it goes back to push only after the rate stays low for hold_ms (hysteresis)" do
      m = Mode.new(hold_ms: 30_000)
      {m, _} = post(m, "d", 0)
      {m, :pull} = post(m, "d", 100)

      # one post every 20 s: rate well under lo, but the hold has not run out
      {m, :pull} = post(m, "d", 20_000)
      {m, :pull} = post(m, "d", 40_000)
      {_m, :push} = post(m, "d", 60_000)
    end

    test "a burst in the middle of the hold restarts it" do
      m = Mode.new(hold_ms: 30_000)
      {m, _} = post(m, "d", 0)
      {m, :pull} = post(m, "d", 100)
      {m, :pull} = post(m, "d", 25_000)
      {m, :pull} = post(m, "d", 25_500)
      # the first low reading was at 25 s, so 56 s would be enough, but the burst reset it
      {m, :pull} = post(m, "d", 56_000)
      assert {_, :push} = post(m, "d", 90_000)
    end

    test "a failed push forces pull for the penalty, whatever the rate" do
      m = Mode.new(penalty_ms: 60_000, hold_ms: 1_000)
      {m, :push} = post(m, "d", 0)
      m = Mode.observe_failure(m, "d", 1_000)
      {m, :pull} = post(m, "d", 20_000)
      {m, :pull} = post(m, "d", 50_000)
      # penalty over and the hold elapsed
      {m, _} = post(m, "d", 62_000)
      assert {_, :push} = post(m, "d", 70_000)
    end
  end

  describe "hybrid routing at the origin" do
    defp origin do
      Origin.new() |> Origin.follow("b.example", @a) |> Origin.follow("c.example", @a)
    end

    test "quiet: the activity itself is pushed with the chain token, nothing is marked for notification" do
      {o, {:routed, 1}, pushes} = Origin.publish_routed(origin(), @a, note("1"), 0)
      assert [{"b.example", p1}, {"c.example", _}] = pushes
      assert p1.prev == nil and p1.etag == "s.1" and p1.key == @a
      assert o.dirty == %{}

      {_, {:routed, 2}, [{_, p2} | _]} = Origin.publish_routed(o, @a, note("2"), 10_000)
      assert p2.prev == "s.1" and p2.etag == "s.2"
    end

    test "dense: after two posts in a window the domain is notified instead" do
      {o, _, [_, _]} = Origin.publish_routed(origin(), @a, note("1"), 0)
      {o, _, pushes} = Origin.publish_routed(o, @a, note("2"), 200)
      assert pushes == []
      assert Map.keys(o.dirty) == ["b.example", "c.example"]
    end

    test "a failed push moves that domain to pull and marks it, without a retry" do
      {o, _, _} = Origin.publish_routed(origin(), @a, note("1"), 0)
      o = Origin.push_failed(o, "b.example", @a, 100)
      assert Map.keys(o.dirty) == ["b.example"]
      {_, _, pushes} = Origin.publish_routed(o, @a, note("2"), 10_000)
      assert Enum.map(pushes, &elem(&1, 0)) == ["c.example"]
    end

    test "direct messages are not routed at all" do
      assert {_, :push_only, []} = Origin.publish_routed(origin(), @a, note("dm", :direct), 0)
    end
  end

  describe "receiving a push with the chain token" do
    defp puller, do: Puller.new() |> Puller.follow("a.example", @a)
    defp payload(n, prev), do: %{key: @a, etag: "s.#{n}", prev: prev, activity: note("p#{n}")}

    test "the next link advances the cursor and needs no pull" do
      {b, :advanced} = Puller.receive_push(puller(), "a.example", payload(1, nil), 0)
      {b, :advanced} = Puller.receive_push(b, "a.example", payload(2, "s.1"), 1)
      assert b.cursors["a.example"][@a] == "s.2"
      assert b.pending == %{}
      assert Map.keys(b.store) |> Enum.sort() == ["p1", "p2"]
    end

    test "a gap stores the activity and plans a pull for the key" do
      {b, :advanced} = Puller.receive_push(puller(), "a.example", payload(1, nil), 0)
      {b, :planned} = Puller.receive_push(b, "a.example", payload(4, "s.3"), 1)
      assert b.cursors["a.example"][@a] == "s.1"
      assert b.pending["a.example"] == %{@a => "s.4"}
      assert Map.has_key?(b.store, "p4")
    end

    test "an old or repeated push changes nothing" do
      {b, _} = Puller.receive_push(puller(), "a.example", payload(1, nil), 0)
      {b, _} = Puller.receive_push(b, "a.example", payload(2, "s.1"), 1)
      assert {^b, :noop} = Puller.receive_push(b, "a.example", payload(1, nil), 2)
    end

    test "a push for an actor we do not follow, or with a bad signature, is dropped" do
      assert {_, :ignored} =
               Puller.receive_push(
                 puller(),
                 "a.example",
                 %{payload(1, nil) | key: "https://x/u"},
                 0
               )

      bad = Puller.new(verify: fn _ -> :error end) |> Puller.follow("a.example", @a)
      {b, :rejected} = Puller.receive_push(bad, "a.example", payload(1, nil), 0)
      assert b.cursors == %{} and b.rejected == 1
    end
  end

  describe "the hybrid end to end (Compare)" do
    defp scenario(prefix),
      do: Enum.find(Compare.scenarios(), &String.starts_with?(&1.name, prefix))

    test "quiet traffic behaves like push" do
      sc = scenario("steady")
      push = Compare.run(:push, sc)
      hybrid = Compare.run(:hybrid, sc)
      assert hybrid.requests_to_b == push.requests_to_b
      assert hybrid.latency_max_ms == push.latency_max_ms
    end

    test "a burst behaves like pull: nothing rejected, a fraction of push's requests" do
      sc = scenario("burst: ")
      push = Compare.run(:push, sc)
      hybrid = Compare.run(:hybrid, sc)
      assert hybrid.failed_requests == 0
      assert hybrid.requests_to_b * 5 < push.requests_to_b
      assert hybrid.latency_p99_ms < push.latency_p99_ms
    end

    test "mixed traffic: fewer requests than either, tail latency like pull" do
      sc = scenario("mixed")
      [push, pull, hybrid] = Enum.map([:push, :pull, :hybrid], &Compare.run(&1, sc))
      assert hybrid.requests_to_b < push.requests_to_b
      assert hybrid.requests_to_b < pull.requests_to_b
      assert hybrid.latency_p99_ms < push.latency_p99_ms
    end

    test "everything is delivered in every scenario, outage included" do
      for sc <- Compare.scenarios() do
        %{delivered: d} = Compare.run(:hybrid, sc)
        assert d == "#{length(sc.events)}/#{length(sc.events)}", sc.name
      end
    end
  end
end
