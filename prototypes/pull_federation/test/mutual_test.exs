# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule MutualTest do
  use ExUnit.Case, async: true

  alias PullFederation.{Mutual, Origin}

  test "separate pools: two servers pulling from each other deliver everything" do
    assert %{complete: true, refused: 0} = Mutual.run()
  end

  test "both servers busy for 20 s: nothing is lost, everything arrives soon after" do
    r = Mutual.run(busy: [{5_000, 25_000}])
    assert r.complete
    assert r.last_delivery_ms < 25_000 + 30_000
  end

  test "one shared worker each and a lockstep backoff is a livelock" do
    for jitter <- [:none, :same] do
      r = Mutual.run(workers: 1, shared: true, jitter: jitter)
      refute r.complete
      assert r.a_to_b == "0/100" and r.b_to_a == "0/100"
    end
  end

  test "random jitter alone usually gets out of it, but only by luck" do
    assert Mutual.run(workers: 1, shared: true, jitter: :random).complete
  end

  test "the tie-break makes the shared single worker case live, whatever the jitter" do
    for jitter <- [:none, :same, :random] do
      r = Mutual.run(workers: 1, shared: true, jitter: jitter, tie_break: true)
      assert r.complete, "jitter #{jitter}"
    end
  end

  test "reserving a worker for serving keeps a shared pool live" do
    r = Mutual.run(workers: 2, shared: true, reserve: 1, jitter: :same)
    assert r.complete and r.refused == 0
  end

  test "a receiver that hangs mid-stream is reaped; with no timeout the slot is lost" do
    ok = Mutual.run(stall: 2)
    assert ok.complete and ok.reaped == 4 and ok.slots_left == 0

    stuck = Mutual.run(stall: 2, stream_timeout_ms: 100_000_000)
    refute stuck.complete
    assert stuck.slots_left > 0
  end

  test "a shared pool with a hung receiver recovers because the count reaps by itself" do
    r = Mutual.run(workers: 1, shared: true, tie_break: true, stall: 2)
    assert r.complete and r.slots_left == 0
  end

  test "random configurations (workers, pool, jitter, busy windows, hangs, RTT) all complete" do
    :rand.seed(:exsss, {5, 5, 5})

    for seed <- 1..40 do
      w = Enum.random([1, 2, 3, 4])

      busy =
        for _ <- 1..Enum.random([1, 2, 3]) do
          s = Enum.random(0..40) * 1_000
          {s, s + Enum.random(2..20) * 1_000}
        end

      o = [
        seed: seed,
        workers: w,
        shared: Enum.random([true, false]),
        jitter: Enum.random([:none, :same, :random]),
        tie_break: true,
        reserve: min(Enum.random([0, 1]), w - 1),
        busy: busy,
        stall: Enum.random([0, 2]),
        stream_ms: Enum.random([100, 300, 1_000]),
        rtt_ms: Enum.random([0, 100, 600, 2_000]),
        until_ms: 400_000
      ]

      assert Mutual.run(o).complete, inspect(o)
    end
  end

  describe "Origin stream slots" do
    setup do
      o = Origin.new(max_streams: 2, stream_timeout_ms: 1_000) |> Origin.follow("b", "x")
      {:ok, o: o}
    end

    test "a domain with a stream open is refused another until it closes", %{o: o} do
      {o, {:ok, _, _}} = Origin.request_stream(o, "b", %{}, 0)
      assert {_, {:error, {:busy, 900}}} = Origin.request_stream(o, "b", %{}, 100)
      o = Origin.close_stream(o, "b", 150)
      assert {_, {:ok, _, _}} = Origin.request_stream(o, "b", %{}, 200)
    end

    test "an unclosed stream is reaped after the timeout and closing late does not double free",
         %{o: o} do
      {o, {:ok, _, _}} = Origin.request_stream(o, "b", %{}, 0)
      o = Origin.reap(o, 1_001)
      assert o.active_streams == 0 and o.reaped == 1
      o = Origin.close_stream(o, "b", 1_500)
      assert o.active_streams == 0
    end
  end
end
