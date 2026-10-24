# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CompareTest do
  use ExUnit.Case, async: true

  alias PullFederation.{Compare, PushOrigin}

  defp scenario(prefix), do: Enum.find(Compare.scenarios(), &String.starts_with?(&1.name, prefix))

  test "push retries back off and give up at the cap" do
    act = %{id: "x", type: :create, visibility: :public}
    o = PushOrigin.publish(PushOrigin.new(max_attempts: 2), act, ["b"], 0)
    {o, [job]} = PushOrigin.due(o, 0)
    o = PushOrigin.result(o, job, :fail, 0)
    assert {_, []} = PushOrigin.due(o, 15_999)
    {o, [job]} = PushOrigin.due(o, 40_000)
    o = PushOrigin.result(o, job, :fail, 40_000)
    assert o.dropped == 1 and o.jobs == []
  end

  test "both models deliver everything in every scenario" do
    for sc <- Compare.scenarios(), model <- [:push, :pull] do
      %{delivered: d} = Compare.run(model, sc)
      assert d == "#{length(sc.events)}/#{length(sc.events)}", "#{model} / #{sc.name}"
    end
  end

  test "under a burst pull asks B for far fewer requests and never fails one" do
    sc = scenario("burst: ")
    push = Compare.run(:push, sc)
    pull = Compare.run(:pull, sc)
    assert pull.requests_to_b * 3 < push.requests_to_b
    assert pull.failed_requests == 0 and push.failed_requests > 0
    assert pull.latency_p99_ms < push.latency_p99_ms
  end

  test "in steady state push is faster and cheaper" do
    sc = scenario("steady")
    push = Compare.run(:push, sc)
    pull = Compare.run(:pull, sc)
    assert push.requests_to_b < pull.requests_to_b
    assert push.latency_max_ms <= pull.latency_max_ms
  end

  test "fan-out: pull's origin cost grows slower than push as followers' domains grow" do
    alias PullFederation.FanOut

    small = [domains: 100, posts: 100]
    big = [domains: 1_000, posts: 100]

    ratio = fn opts ->
      FanOut.run(:push, opts).origin_cost_units / FanOut.run(:pull, opts).origin_cost_units
    end

    assert ratio.(small) > 1.0
    assert ratio.(big) > 5.0
    assert FanOut.run(:push, big).db_writes > 100 * FanOut.run(:pull, big).db_writes
    assert FanOut.run(:pull, big).peak_queue_entries < FanOut.run(:push, big).peak_queue_entries
  end

  test "snapshot notifications are smaller, but cost more on the wire once fetches count" do
    alias PullFederation.NotifyCost
    o = [follow_k: 1500, posts: 300, domains: 40]
    inline = NotifyCost.run(100_000, o)
    snap = NotifyCost.run(0, o)

    assert snap.avg_notification_bytes < inline.avg_notification_bytes
    assert snap.total_wire_bytes > inline.total_wire_bytes
    assert snap.origin_renders < snap.snapshot_fetches
  end

  describe "which one for which rate (FanOut.per_domain/3)" do
    alias PullFederation.FanOut

    test "rare posts: push is cheaper for both sides, whatever the follower count" do
      r = FanOut.per_domain(10, 600_000)
      assert r.posts_per_notification == 1.0
      assert r.push_origin < r.pull_origin
      assert r.push_b < r.pull_b
    end

    test "dense posts: pull wins on both sides, more as batches grow" do
      mid = FanOut.per_domain(600, 600_000)
      dense = FanOut.per_domain(2_000, 600_000)
      assert mid.pull_origin < mid.push_origin
      assert dense.push_origin / dense.pull_origin > mid.push_origin / mid.pull_origin
      assert dense.pull_b < dense.push_b
    end

    test "the break-even depends on posts per quiet period, not on the follower count" do
      # 300 posts in 10 min = one per 2 s: 1.5 per 3 s window
      r = FanOut.per_domain(300, 600_000, 3_000)
      assert r.posts_per_notification > 1.0
      # a longer quiet period batches the same traffic harder
      longer = FanOut.per_domain(300, 600_000, 10_000)
      assert longer.posts_per_notification > 3 * r.posts_per_notification
    end

    test "origin cost grows almost linearly with the number of domains" do
      one = FanOut.run(:push, domains: 10, posts: 20)
      many = FanOut.run(:push, domains: 100, posts: 20)
      # a small per-post part (serialize once, sign the activity once) does not scale
      ratio = many.origin_cost_units / one.origin_cost_units
      assert ratio > 8.5 and ratio < 10.0
    end
  end
end
