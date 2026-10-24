# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Flood do
  @moduledoc """
  Two hostile workloads.

    * `fake_notifications/0`: forged notifications aimed at B. For each
      attack it reports what B accepted, what it spent, and what B's state
      looked like afterwards.
    * `stampede/1`: `domains` receivers all want to pull from one origin
      at the same time. It reports what the origin had to absorb and how
      long convergence took, with and without jitter, with B-side lazy
      start, and with receivers that ignore the decline and hammer.

  Origin cost per request uses the `FanOut` table: a decline costs
  `verify + send` (1.3); an admitted pull costs `verify + send + db_scan +
  rows * db_row` (3.3 + 0.05 per row).
  """

  alias PullFederation.{Origin, Puller}

  @actor "https://a.example/users/alice"
  @decline_cost 1.3
  @admit_cost 3.3

  # --- forged notifications ---------------------------------------------------

  def fake_notifications do
    [
      garbage_shapes(),
      oversize(),
      unknown_origins(),
      unfollowed_actors(),
      known_origin_flood(),
      forged_future_etag(),
      forged_buckets()
    ]
  end

  defp b do
    Puller.new()
    |> Puller.follow("a.example", @actor)
    |> Puller.follow("a.example", @actor <> "#followers")
  end

  defp state_size(p) do
    map_size(p.pending) + map_size(p.last_accepted) + map_size(p.wanted) + map_size(p.following)
  end

  defp garbage_shapes do
    junk = [
      nil,
      42,
      "str",
      [],
      %{1 => "o.x"},
      %{@actor => 7},
      %{@actor => "plain"},
      %{@actor => "s.-1"},
      {:buckets, %{1 => 2}, %{}},
      {:buckets, %{"ab" => "x"}, %{}},
      {:buckets, %{}, "nope"}
    ]

    {p, results} =
      Enum.reduce(Enum.with_index(junk), {b(), []}, fn {n, i}, {p, acc} ->
        {p, r} = Puller.notify(p, "a.example", n, i * 2_000)
        {p, [r | acc]}
      end)

    %{
      attack: "malformed payloads (#{length(junk)} shapes)",
      sent: length(junk),
      accepted: Enum.count(results, &(&1 != :invalid)),
      pulls_caused: map_size(p.pending),
      state_growth: state_size(p) - state_size(b())
    }
  end

  defp oversize do
    big = for i <- 1..1_001, into: %{}, do: {"k#{i}", "o.x"}
    versions = for i <- 1..257, into: %{}, do: {"b#{i}", 1}
    {p, r1} = Puller.notify(b(), "a.example", big, 0)
    {p, r2} = Puller.notify(p, "a.example", {:buckets, versions, %{}}, 5_000)

    %{
      attack: "oversize maps (1001 entries, 257 buckets)",
      sent: 2,
      accepted: Enum.count([r1, r2], &(&1 != :invalid)),
      pulls_caused: map_size(p.pending),
      state_growth: state_size(p) - state_size(b())
    }
  end

  defp unknown_origins do
    n = 10_000

    p =
      Enum.reduce(1..n, b(), fn i, p ->
        elem(Puller.notify(p, "evil#{i}.example", %{@actor => "o.x#{i}"}, i), 0)
      end)

    %{
      attack: "#{n} notifications from #{n} invented origins",
      sent: n,
      accepted: 0,
      pulls_caused: map_size(p.pending),
      state_growth: state_size(p) - state_size(b())
    }
  end

  defp unfollowed_actors do
    n = 10_000
    forged = for i <- 1..n, into: %{}, do: {"https://x.example/users/u#{i}", "o.t#{i}"}

    {p, r} =
      Puller.notify(b(), "a.example", Map.take(forged, Enum.take(Map.keys(forged), 1_000)), 0)

    %{
      attack: "1,000 actors B does not follow, from a known origin",
      sent: 1,
      accepted: if(r == :up_to_date, do: 0, else: 1),
      pulls_caused: map_size(p.pending),
      state_growth: state_size(p) - state_size(b())
    }
  end

  # An attacker who can send as a known origin (or the origin itself misbehaving):
  # 10,000 notifications with fresh random tokens in 10 seconds.
  defp known_origin_flood do
    n = 10_000
    a = Origin.new() |> Origin.follow("b.example", @actor)
    {a, _} = Origin.publish(a, @actor, %{id: "real", type: :create, visibility: :public})

    {p, a, accepted, pulls, events} =
      Enum.reduce(1..n, {b(), a, 0, 0, 0}, fn i, {p, a, acc, pulls, ev} ->
        now = div(i * 10_000, n)
        {p, r} = Puller.notify(p, "a.example", %{@actor => "o.forged#{i}"}, now)
        acc = if r == :planned, do: acc + 1, else: acc

        # B pulls whenever it has something pending and is not busy
        case Puller.next_pull(p, now, false) do
          {:pull, "a.example", cursors} ->
            p = Puller.begin_pull(p, "a.example")
            {:ok, a, evs, ann} = Origin.open_stream(a, "b.example", cursors, now)
            p = Puller.finish_pull(p, "a.example", {:ok, evs, ann}, now, fn _ -> 0 end)
            {p, Origin.close_stream(a), acc, pulls + 1, ev + length(evs)}

          _ ->
            {p, a, acc, pulls, ev}
        end
      end)

    _ = a

    %{
      attack: "#{n} forged-token notifications in 10 s from a known origin",
      sent: n,
      accepted: accepted,
      pulls_caused: pulls,
      delivered_events: events,
      state_growth: state_size(p) - state_size(b())
    }
  end

  # A forged "ordered" token far in the future must not hide real news later.
  defp forged_future_etag do
    a = Origin.new() |> Origin.follow("b.example", @actor)
    act = fn id -> %{id: id, type: :create, visibility: :public} end
    {a, _} = Origin.publish(a, @actor, act.("one"))

    p = b()
    {p, :planned} = Puller.notify(p, "a.example", %{@actor => "s.999999999"}, 0)
    {:pull, "a.example", cursors} = Puller.next_pull(p, 0, false)
    p = Puller.begin_pull(p, "a.example")
    {:ok, a, evs, ann} = Origin.open_stream(a, "b.example", cursors, 0)
    p = Puller.finish_pull(p, "a.example", {:ok, evs, ann}, 0, fn _ -> 0 end)
    a = Origin.close_stream(a)

    cursor_after_forgery = p.cursors["a.example"][@actor]

    # now a real update arrives
    {a, _} = Origin.publish(a, @actor, act.("two"))
    {_, [{"b.example", real}]} = Origin.due_notifications(a, 5_000)
    {p, status} = Puller.notify(p, "a.example", real, 5_000)

    %{
      attack: "forged ordered token s.999999999, then a real update",
      sent: 2,
      accepted: 2,
      pulls_caused: 1,
      cursor_poisoned: cursor_after_forgery != "s.1",
      real_update_seen: status == :planned,
      state_growth: state_size(p) - state_size(b())
    }
  end

  defp forged_buckets do
    mine = Puller.new() |> Puller.follow("a.example", @actor)
    all = for i <- 0..255, into: %{}, do: {Base.encode16(<<i>>, case: :lower), 999_999}
    {p, r} = Puller.notify(mine, "a.example", {:buckets, all, %{}}, 0)

    %{
      attack: "bucket versions for all 256 buckets (B follows one actor)",
      sent: 1,
      accepted: if(r == :fetch, do: 1, else: 0),
      pulls_caused: 0,
      buckets_fetched: length(Puller.wanted_buckets(p, "a.example")),
      state_growth: state_size(p) - state_size(mine)
    }
  end

  # --- stampede ---------------------------------------------------------------------

  @doc """
  Options: `domains`, `max_streams`, `stream_ms`, `jitter` (:none | :full),
  `lazy_spread_ms` (B-side start delay, 0 = pull at once), `hammer` (receivers
  ignore declines and retry every 100 ms), `min_pull_gap_ms`, `reserve_ms`
  (appointment horizon; 0 = no appointments, receivers guess a backoff), `horizon_ms`.
  """
  def stampede(opts \\ []) do
    p =
      Map.merge(
        %{
          domains: 1_000,
          max_streams: 8,
          stream_ms: 400,
          jitter: :full,
          lazy_spread_ms: 0,
          hammer: false,
          min_pull_gap_ms: 0,
          reserve_ms: 300_000,
          horizon_ms: 900_000
        },
        Map.new(opts)
      )

    origin =
      Enum.reduce(
        1..p.domains,
        Origin.new(
          max_streams: p.max_streams,
          min_pull_gap_ms: p.min_pull_gap_ms,
          calendar: [horizon_ms: p.reserve_ms, slot_ms: round(p.stream_ms / p.max_streams / 0.8)]
        ),
        fn d, acc ->
          Origin.follow(acc, "d#{d}", @actor)
        end
      )

    {origin, _} =
      Origin.publish(origin, @actor, %{id: "post", type: :create, visibility: :public})

    {_, [_ | _] = notes} = Origin.due_notifications(origin, 0)
    announced = Map.new(notes)

    jit =
      case p.jitter do
        :none -> fn _ -> 0 end
        :full -> fn max -> :rand.uniform(max + 1) - 1 end
      end

    :rand.seed(:exsss, {7, 7, 7})

    bs =
      for d <- 1..p.domains, into: %{} do
        {"d#{d}", puller_for(announced["d#{d}"]) |> then(&%{p: &1, start: start(p)})}
      end

    queue = Enum.reduce(bs, :gb_sets.empty(), fn {d, st}, q -> :gb_sets.add({st.start, d}, q) end)

    st = %{
      origin: origin,
      bs: bs,
      queue: queue,
      done: :gb_sets.empty(),
      reqs: 0,
      declined: 0,
      admitted: 0,
      peak_active: 0,
      per_sec: %{},
      converged: %{}
    }

    st = run(st, p, jit)
    report(st, p)
  end

  defp puller_for(announced) do
    pl = Puller.new() |> Puller.follow("a.example", @actor)
    {pl, :planned} = Puller.notify(pl, "a.example", announced, 0)
    pl
  end

  defp start(%{lazy_spread_ms: 0}), do: 0
  defp start(%{lazy_spread_ms: n}), do: :rand.uniform(n)

  # event loop over {time, id} for B wake-ups and {time, {:close, d}} for stream ends
  defp run(st, p, jit) do
    next_b =
      :gb_sets.is_empty(st.queue) |> then(&if(&1, do: nil, else: :gb_sets.smallest(st.queue)))

    next_c =
      :gb_sets.is_empty(st.done) |> then(&if(&1, do: nil, else: :gb_sets.smallest(st.done)))

    case {next_b, next_c} do
      {nil, nil} -> st
      {b, c} -> step(st, p, jit, pick(b, c))
    end
  end

  defp pick(nil, c), do: {:close, c}
  defp pick(b, nil), do: {:wake, b}
  defp pick({tb, _} = b, {tc, _} = c), do: if(tc <= tb, do: {:close, c}, else: {:wake, b})

  defp step(st, p, jit, {:close, {t, d} = item}) do
    done = :gb_sets.delete(item, st.done)
    bst = st.bs[d]

    pl =
      Puller.finish_pull(
        bst.p,
        "a.example",
        {:ok, [], Origin.announced(st.origin, d)},
        t,
        jit
      )

    st = %{
      st
      | done: done,
        origin: Origin.close_stream(st.origin, d, t),
        bs: Map.put(st.bs, d, %{bst | p: pl}),
        converged: Map.put(st.converged, d, t)
    }

    run(st, p, jit)
  end

  defp step(st, p, jit, {:wake, {t, d} = item}) do
    st = %{st | queue: :gb_sets.delete(item, st.queue)}
    bst = st.bs[d]

    case t > p.horizon_ms do
      true -> run(st, p, jit)
      false -> wake(st, p, jit, t, d, bst)
    end
  end

  defp wake(st, p, jit, t, d, bst) do
    decision =
      case {p.hammer, Puller.next_pull(bst.p, t, t < bst.start)} do
        {true, :idle} when map_size(bst.p.pending) > 0 -> {:pull, "a.example", %{}}
        {_, other} -> other
      end

    case decision do
      {:pull, "a.example", cursors} ->
        pl = Puller.begin_pull(bst.p, "a.example")
        sec = div(t, 1_000)
        st = %{st | reqs: st.reqs + 1, per_sec: Map.update(st.per_sec, sec, 1, &(&1 + 1))}

        {origin, answer} = Origin.request_stream(st.origin, d, cursors, t)
        st = %{st | origin: origin}

        case answer do
          {:ok, _events, _ann} ->
            origin = st.origin

            st = %{
              st
              | origin: origin,
                admitted: st.admitted + 1,
                peak_active: max(st.peak_active, origin.active_streams),
                done: :gb_sets.add({t + p.stream_ms, d}, st.done),
                bs: Map.put(st.bs, d, %{bst | p: pl})
            }

            run(st, p, jit)

          {:error, err} ->
            pl = Puller.finish_pull(pl, "a.example", {:error, err}, t, jit)
            next = if p.hammer, do: t + 100, else: Map.get(pl.not_before, "a.example", t + 100)

            st = %{
              st
              | declined: st.declined + 1,
                bs: Map.put(st.bs, d, %{bst | p: pl}),
                queue: :gb_sets.add({next, d}, st.queue)
            }

            run(st, p, jit)
        end

      :postponed ->
        run(%{st | queue: :gb_sets.add({bst.start, d}, st.queue)}, p, jit)

      :idle ->
        run(st, p, jit)
    end
  end

  defp report(st, p) do
    times = st.converged |> Map.values() |> Enum.sort()
    n = length(times)
    peak = st.per_sec |> Map.values() |> Enum.max(fn -> 0 end)

    %{
      domains: p.domains,
      converged: "#{n}/#{p.domains}",
      pull_requests_at_origin: st.reqs,
      declined: st.declined,
      admitted: st.admitted,
      peak_requests_per_s: peak,
      peak_active_streams: st.peak_active,
      last_converged_ms: List.last(times),
      p50_converged_ms: Enum.at(times, div(n, 2)),
      origin_cost_units: Float.round(st.declined * @decline_cost + st.admitted * @admit_cost, 1)
    }
  end
end
