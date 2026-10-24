# SPDX-License-Identifier: AGPL-3.0-or-later
# Real processes, real clock: one origin process (single writer) and many
# receiver processes pulling from it. Run: mix run bench/concurrent.exs [domains] [posts_per_s] [seconds]
alias PullFederation.{Etag, Origin, Puller}

defmodule Srv do
  use GenServer
  # Service time per call, in microseconds, times COST (env, default 0): what the
  # database and the signature cost on a loaded server. A busy-wait, so the
  # origin process really is occupied for that long.
  def spin(us) do
    f = :persistent_term.get(:cost, 0.0)
    n = round(us * f)
    if n > 0 do
      t = System.monotonic_time(:microsecond)
      spin_until(t + n)
    end
  end
  defp spin_until(t), do: if(System.monotonic_time(:microsecond) < t, do: spin_until(t), else: :ok)

  def start_link(o), do: GenServer.start_link(__MODULE__, o)
  def init(o), do: {:ok, %{o: o, pids: %{}, calls: 0}}
  def handle_call({:register, d, pid}, _, s), do: {:reply, :ok, put_in(s.pids[d], pid)}
  def handle_call({:publish, actor, act}, _, s) do
    spin(300)
    {o, _} = Origin.publish(s.o, actor, act)
    {:reply, :ok, %{s | o: o, calls: s.calls + 1}}
  end
  def handle_call({:request, d, cursors}, _, s) do
    spin(300)
    {o, ans} = Origin.request_stream(s.o, d, cursors, now())
    {:reply, ans, %{s | o: o, calls: s.calls + 1}}
  end
  def handle_call({:bucket, b}, _, s), do: spin(100) |> then(fn _ -> {:reply, Origin.bucket_doc(s.o, b), s} end)

  def handle_call({:close, d}, _, s),
    do: {:reply, :ok, %{s | o: Origin.close_stream(s.o, d, now()), calls: s.calls + 1}}
  def handle_call(:pids, _, s), do: {:reply, s.pids, s}
  def handle_call(:origin, _, s), do: {:reply, s.o, s}

  def handle_call(:stats, _, s),
    do: {:reply, %{calls: s.calls, active: s.o.active_streams, booked: s.o.calendar.booked, dirty: map_size(s.o.dirty), reaped: s.o.reaped}, s}
  def handle_info(:tick, s) do
    {o, notes} = Origin.due_notifications(s.o, now())
    for {d, ann} <- notes, do: send(s.pids[d], {:notify, ann})
    {:noreply, %{s | o: o}}
  end
  def now, do: System.system_time(:millisecond)
end

defmodule Recv do
  def start(srv, domain, actors, stream_ms, lag_tab) do
    spawn_link(fn ->
      :ok = GenServer.call(srv, {:register, domain, self()}, 60_000)
      b = Enum.reduce(actors, Puller.new(max_pending: 100_000), &Puller.follow(&2, "o", &1))
      loop(b, srv, domain, stream_ms, lag_tab)
    end)
  end

  defp loop(b, srv, domain, stream_ms, lag_tab) do
    wait =
      case Puller.next_pull(b, Srv.now(), false) do
        {:pull, "o", _} -> 0
        _ -> :infinity
      end

    # wake for a notification, or when a postponed pull is due
    timeout = if map_size(b.pending) > 0 or map_size(b.stale) > 0, do: max(wait_for(b), 0), else: wait
    receive do
      {:dump, from} ->
        send(from, {:state, domain, b})
        loop(b, srv, domain, stream_ms, lag_tab)

      {:notify, ann} ->
        {b, st} = Puller.notify(b, "o", ann, Srv.now())
        :ets.insert(lag_tab, {:trace, domain, Srv.now(), {:notify, st, if(is_map(ann), do: map_size(ann), else: :buckets), map_size(Map.get(b.pending, "o", %{}))}})

        # a notification that points at snapshot buckets: fetch them (static GETs)
        b =
          for bucket <- Puller.wanted_buckets(b, "o"), reduce: b do
            acc ->
              doc = GenServer.call(srv, {:bucket, bucket}, 60_000)
              elem(Puller.ingest_bucket(acc, "o", bucket, doc, Srv.now()), 0)
          end

        loop(b, srv, domain, stream_ms, lag_tab)
    after
      timeout ->
        b = pull(b, srv, domain, stream_ms, lag_tab)
        loop(b, srv, domain, stream_ms, lag_tab)
    end
  end

  # Admission control in front of the origin process: at most `limit` requests
  # waiting for it; the rest are refused at once (a 503 with Retry-After), without
  # touching its mailbox. limit 0 = no gate.
  defp gated_request(srv, domain, cursors, lag_tab) do
    {ref, limit} = :persistent_term.get(:gate)

    case limit > 0 and :atomics.add_get(ref, 1, 1) > limit do
      true ->
        :atomics.sub(ref, 1, 1)
        :ets.insert(lag_tab, {:shed, 1})
        {:error, {:busy, 500 + :rand.uniform(1000)}}

      false ->
        try do
          GenServer.call(srv, {:request, domain, cursors}, 120_000)
        after
          if limit > 0, do: :atomics.sub(ref, 1, 1)
        end
    end
  end

  defp wait_for(b) do
    gap = if b.stale["o"], do: Map.get(b.last_accepted, "o", 0) + b.min_notify_gap_ms - Srv.now(), else: 0
    max(Map.get(b.not_before, "o", 0) - Srv.now(), gap)
  end

  defp pull(b, srv, domain, stream_ms, lag_tab) do
    case Puller.next_pull(b, Srv.now(), false) do
      {:pull, "o", cursors} ->
        b = Puller.begin_pull(b, "o")
        t0 = Srv.now()
        ans = gated_request(srv, domain, cursors, lag_tab)
        :ets.insert(lag_tab, {:trace, domain, Srv.now(), {:ans, (case ans do {:ok, ev, _} -> {:ok, length(ev)}; {:error, e} -> e end)}})
        :ets.insert(lag_tab, {:call_us, (Srv.now() - t0)})

        case ans do
          {:ok, events, ann} ->
            Process.sleep(stream_ms)
            GenServer.call(srv, {:close, domain}, 60_000)
            now = Srv.now()
            for e <- events, do: :ets.insert(lag_tab, {:lag, now - e.activity.at})
            Puller.finish_pull(b, "o", {:ok, events, ann}, now, fn m -> :rand.uniform(m + 1) - 1 end)

          err ->
            :ets.insert(lag_tab, {:declined, elem(elem(err, 1), 0)})
            Puller.finish_pull(b, "o", err, Srv.now(), fn m -> :rand.uniform(m + 1) - 1 end)
        end

      _ ->
        b
    end
  end
end

[domains, rate, secs, quiet] =
  case System.argv() do
    [] -> [1000, 1000, 10, 1000]
    args -> Enum.map(args, &String.to_integer/1) |> then(&(&1 ++ [1000]) |> Enum.take(4))
  end

n_actors = 200
follow_per_actor = max(div(domains, 10), 1)
:rand.seed(:exsss, {1, 1, 1})

origin =
  Enum.reduce(1..n_actors, Origin.new(max_streams: 64, notify_quiet_ms: quiet), fn a, o ->
    for d <- Enum.take_random(1..domains, follow_per_actor), reduce: o do
      o -> Origin.follow(o, "d#{d}", "u#{a}")
    end
  end)

follows = origin.follows
cost = System.get_env("COST", "0") |> then(&if(String.contains?(&1, "."), do: String.to_float(&1), else: String.to_float(&1 <> ".0")))
gate = System.get_env("GATE", "0") |> String.to_integer()
settle = System.get_env("SETTLE", "10") |> String.to_integer()
:persistent_term.put(:cost, cost)
:persistent_term.put(:gate, {:atomics.new(1, []), gate})
{:ok, srv} = Srv.start_link(origin)
lag = :ets.new(:lag, [:public, :duplicate_bag, write_concurrency: true])

for d <- 1..domains do
  Recv.start(srv, "d#{d}", MapSet.to_list(Map.get(follows, "d#{d}", MapSet.new())), 5, lag)
end

ticker = spawn_link(fn -> Stream.repeatedly(fn -> Process.sleep(100); send(srv, :tick) end) |> Stream.run() end)

IO.puts("quiet=#{quiet} domains=#{domains} actors=#{n_actors} each followed by #{follow_per_actor} domains; #{rate} posts/s for #{secs}s, 64 stream slots")
t0 = Srv.now()
interval = 100
per = div(rate * interval, 1000)
peak_q = :atomics.new(1, [])

monitor = spawn_link(fn ->
  Stream.repeatedly(fn ->
    Process.sleep(50)
    {:message_queue_len, q} = Process.info(srv, :message_queue_len)
    if q > :atomics.get(peak_q, 1), do: :atomics.put(peak_q, 1, q)
  end) |> Stream.run()
end)

posted =
  Enum.reduce(1..div(secs * 1000, interval), 0, fn i, n ->
    target = t0 + i * interval
    for _ <- 1..per do
      a = :rand.uniform(n_actors)
      :ets.insert(lag, {:posted, a})
      {us, _} = :timer.tc(fn -> GenServer.call(srv, {:publish, "u#{a}", %{id: "p#{n}-#{:rand.uniform(1_000_000)}", type: :create, visibility: :public, at: Srv.now()}}, 120_000) end)
      :ets.insert(lag, {:pub_ms, us / 1000})
    end
    Process.sleep(max(target - Srv.now(), 0))
    n + per
  end)

IO.puts("posted #{posted} in #{Srv.now() - t0} ms (target #{secs * 1000})")
Process.sleep(settle * 1000)
pct = fn xs, p -> xs |> Enum.sort() |> then(&Enum.at(&1, min(round(length(&1) * p) , length(&1) - 1))) end
get = fn k -> for {^k, v} <- :ets.tab2list(lag), do: v end
lags = get.(:lag)
calls = get.(:call_us)
expected =
  for {:posted, a} <- :ets.tab2list(lag), reduce: 0 do
    acc -> acc + Enum.count(follows, fn {_d, as} -> MapSet.member?(as, "u#{a}") end)
  end

pubs = get.(:pub_ms)
IO.puts("COST=#{cost} GATE=#{gate} settle=#{settle}s")
IO.puts("expected deliveries=#{expected}")
IO.puts("author's publish call (save) ms p50=#{Float.round(pct.(pubs, 0.5), 1)} p99=#{Float.round(pct.(pubs, 0.99), 1)} max=#{Float.round(Enum.max(pubs, fn -> 0 end), 1)}  shed=#{length(get.(:shed))}")
IO.puts("server stats: #{inspect(GenServer.call(srv, :stats))}  peak mailbox=#{:atomics.get(peak_q, 1)}")
IO.puts("deliveries=#{length(lags)}  lag ms p50=#{pct.(lags, 0.5)} p99=#{pct.(lags, 0.99)} max=#{Enum.max(lags, fn -> 0 end)}")
IO.puts("pull call (request_stream round trip) ms p50=#{pct.(calls, 0.5)} p99=#{pct.(calls, 0.99)} max=#{Enum.max(calls, fn -> 0 end)}  calls=#{length(calls)}  declined=#{inspect(Enum.frequencies(get.(:declined)))}")
if System.get_env("DUMP") do
  pids = GenServer.call(srv, :pids)
  origin_state = GenServer.call(srv, :origin)
  for {d, pid} <- pids, do: send(pid, {:dump, self()})
  states =
    for _ <- pids do
      receive do {:state, d, b} -> {d, b} after 2000 -> nil end
    end
    |> Enum.reject(&is_nil/1)

  behind =
    for {d, b} <- states,
        ann = Origin.announced(origin_state, d),
        cur = Map.get(b.cursors, "o", %{}),
        diff = PullFederation.Cursors.changed(cur, ann),
        map_size(diff) > 0,
        do: {d, map_size(diff), b.pending["o"] |> then(&(&1 && map_size(&1))), b.stale["o"], b.inflight["o"] |> is_nil(), Map.get(b.not_before, "o"), Map.has_key?(origin_state.dirty, d)}

  IO.puts("domains behind: #{length(behind)} of #{length(states)}")
  case behind do
    [{d, _, _, _, _, _, _} | _] ->
      IO.puts("trace of #{d}:")
      for {:trace, ^d, t, ev} <- :ets.match_object(lag, {:trace, d, :_, :_}) |> Enum.sort_by(&elem(&1, 2)), do: IO.puts("  #{rem(t, 100_000)} #{inspect(ev)}")
    _ -> :ok
  end
  IO.inspect(Enum.take(behind, 8), label: "{domain, keys_behind, pending, stale, no_inflight, not_before, origin_dirty}", limit: :infinity)
end

Process.exit(ticker, :kill); Process.exit(monitor, :kill)
