# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule MnesiaQueueTest do
  use ExUnit.Case, async: false

  @t0 1_000_000

  setup do
    :mnesia.stop()
    :ok = :mnesia.start()
    for t <- [:mq_jobs, :mq_ready, :mq_hosts, :mq_unique, :mq_ids], do: :mnesia.delete_table(t)
    :ok = MnesiaQueue.setup(:ram_copies)
    :ok
  end

  test "enqueue, claim, complete" do
    {:ok, id} = MnesiaQueue.enqueue("a.example", %{n: 1}, @t0)
    assert [%{id: ^id, state: :claimed, attempt: 1}] = MnesiaQueue.claim(@t0, 30_000)
    assert [] = MnesiaQueue.claim(@t0, 30_000)
    assert :ok = MnesiaQueue.complete(id, @t0 + 5)
    assert %{state: :completed} = MnesiaQueue.get(id)
    assert {:error, {:not_claimed, :completed}} = MnesiaQueue.complete(id, @t0 + 6)
  end

  test "scheduled jobs wait until run_at" do
    {:ok, id} = MnesiaQueue.enqueue("a.example", :later, @t0, run_at: @t0 + 60_000)
    assert [] = MnesiaQueue.claim(@t0 + 59_999, 30_000)
    assert [%{id: ^id}] = MnesiaQueue.claim(@t0 + 60_000, 30_000)
  end

  test "per-host cap: a slow host cannot starve the others" do
    for i <- 1..10, do: MnesiaQueue.enqueue("slow.example", i, @t0)
    {:ok, other} = MnesiaQueue.enqueue("fast.example", :x, @t0)

    claimed = MnesiaQueue.claim(@t0, 30_000, limit: 100, host_limit: 4)
    assert Enum.count(claimed, &(&1.host == "slow.example")) == 4
    assert Enum.any?(claimed, &(&1.id == other))
    assert %{"slow.example" => 4} = MnesiaQueue.stats().running_by_host |> Map.take(["slow.example"])

    # finishing one frees a slot
    [first | _] = Enum.filter(claimed, &(&1.host == "slow.example"))
    :ok = MnesiaQueue.complete(first.id, @t0 + 1)
    assert [%{host: "slow.example"}] = MnesiaQueue.claim(@t0 + 1, 30_000, limit: 100, host_limit: 4)
  end

  test "retry with exponential backoff, then dead after max_attempts" do
    {:ok, id} = MnesiaQueue.enqueue("a.example", :p, @t0, max_attempts: 3)

    [%{attempt: 1}] = MnesiaQueue.claim(@t0, 30_000)
    assert {:retry, run_at1} = MnesiaQueue.fail(id, :timeout, @t0)
    assert run_at1 == @t0 + 2_000
    assert [] = MnesiaQueue.claim(run_at1 - 1, 30_000)

    [%{attempt: 2}] = MnesiaQueue.claim(run_at1, 30_000)
    assert {:retry, run_at2} = MnesiaQueue.fail(id, :timeout, run_at1)
    assert run_at2 == run_at1 + 4_000

    [%{attempt: 3}] = MnesiaQueue.claim(run_at2, 30_000)
    assert :dead = MnesiaQueue.fail(id, :boom, run_at2)
    assert %{state: :dead, last_error: :boom} = MnesiaQueue.get(id)
    assert [] = MnesiaQueue.claim(run_at2 + 10_000_000, 30_000)
    assert MnesiaQueue.stats().running_by_host == %{}
  end

  test "unique key de-duplicates live jobs, and frees the key when terminal" do
    {:ok, id} = MnesiaQueue.enqueue("a.example", :p, @t0, unique_key: {"act-1", "inbox"})
    assert {:duplicate, ^id} = MnesiaQueue.enqueue("a.example", :p, @t0, unique_key: {"act-1", "inbox"})

    [%{id: ^id}] = MnesiaQueue.claim(@t0, 30_000)
    :ok = MnesiaQueue.complete(id, @t0)
    assert {:ok, id2} = MnesiaQueue.enqueue("a.example", :p, @t0, unique_key: {"act-1", "inbox"})
    assert id2 != id
  end

  test "lifeline returns expired claims; live leases are left alone" do
    {:ok, a} = MnesiaQueue.enqueue("a.example", :a, @t0)
    {:ok, b} = MnesiaQueue.enqueue("b.example", :b, @t0)
    [_, _] = MnesiaQueue.claim(@t0, 1_000, limit: 2)

    # the worker holding `a` renews nothing and dies; `b` is still inside its lease
    assert 0 = MnesiaQueue.lifeline(@t0 + 500)
    assert 2 = MnesiaQueue.lifeline(@t0 + 1_001)
    assert %{state: :ready, last_error: :lease_expired} = MnesiaQueue.get(a)
    assert %{state: :ready} = MnesiaQueue.get(b)
    assert MnesiaQueue.stats().running_by_host == %{}

    assert [%{attempt: 2}, %{attempt: 2}] = MnesiaQueue.claim(@t0 + 1_001, 1_000, limit: 2)
  end

  test "a job that keeps crashing workers goes dead via lifeline" do
    {:ok, id} = MnesiaQueue.enqueue("a.example", :p, @t0, max_attempts: 2)
    [_] = MnesiaQueue.claim(@t0, 100)
    assert 1 = MnesiaQueue.lifeline(@t0 + 101)
    [_] = MnesiaQueue.claim(@t0 + 101, 100)
    assert 1 = MnesiaQueue.lifeline(@t0 + 202)
    assert %{state: :dead, last_error: :lease_expired} = MnesiaQueue.get(id)
  end

  test "prune removes only old terminal jobs" do
    {:ok, done} = MnesiaQueue.enqueue("a.example", :a, @t0)
    {:ok, live} = MnesiaQueue.enqueue("b.example", :b, @t0)
    [%{id: ^done}] = MnesiaQueue.claim(@t0, 1_000, limit: 1)
    :ok = MnesiaQueue.complete(done, @t0)

    assert 0 = MnesiaQueue.prune(@t0 + 999, 1_000)
    assert 1 = MnesiaQueue.prune(@t0 + 1_001, 1_000)
    assert MnesiaQueue.get(done) == nil
    assert %{state: :ready} = MnesiaQueue.get(live)
  end

  test "concurrent claimers never receive the same job" do
    n = 2_000
    for i <- 1..n, do: MnesiaQueue.enqueue("h#{rem(i, 50)}.example", i, @t0)

    claimed =
      1..8
      |> Task.async_stream(
        fn _ ->
          Stream.repeatedly(fn -> MnesiaQueue.claim(@t0, 60_000, limit: 10, host_limit: 1_000) end)
          |> Enum.take_while(&(&1 != []))
          |> List.flatten()
        end,
        timeout: 60_000
      )
      |> Enum.flat_map(fn {:ok, l} -> l end)

    ids = Enum.map(claimed, & &1.id)
    assert length(ids) == n
    assert length(Enum.uniq(ids)) == n
  end
end
