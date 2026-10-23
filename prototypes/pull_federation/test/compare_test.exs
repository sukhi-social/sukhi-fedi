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
end
