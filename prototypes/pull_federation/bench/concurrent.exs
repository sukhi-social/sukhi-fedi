# SPDX-License-Identifier: AGPL-3.0-or-later
# Real processes, real clock: one origin process (single writer) and many
# receiver processes pulling from it. Run: mix run bench/concurrent.exs [domains] [posts_per_s] [seconds]
alias PullFederation.{Etag, Origin, Puller}

defmodule Srv do
  use GenServer
  def start_link(o), do: GenServer.start_link(__MODULE__, o)
  def init(o), do: {:ok, %{o: o, pids: %{}, calls: 0}}
  def handle_call({:register, d, pid}, _, s), do: {:reply, :ok, put_in(s.pids[d], pid)}
  def handle_call({:publish, actor, act}, _, s) do
    {o, _} = Origin.publish(s.o, actor, act)
    {:reply, :ok, %{s | o: o, calls: s.calls + 1}}
  end
  def handle_call({:request, d, cursors}, _, s) do
    {o, ans} = Origin.request_stream(s.o, d, cursors, now())
    {:reply, ans, %{s | o: o, calls: s.calls + 1}}
  end
  def handle_call({:bucket, b}, _, s), do: {:reply, Origin.bucket_doc(s.o, b), s}

  def handle_call({:close, d}, _, s),
    do: {:reply, :ok, %{s | o: Origin.close_stream(s.o, d, now()), calls: s.calls + 1}}
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
    timeout = if map_size(b.pending) > 0, do: max(wait_for(b), 0), else: wait
    receive do
      {:notify, ann} ->
        {b, _} = Puller.notify(b, "o", ann, Srv.now())

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

  defp wait_for(b), do: Map.get(b.not_before, "o", 0) - Srv.now()

  defp pull(b, srv, domain, stream_ms, lag_tab) do
    case Puller.next_pull(b, Srv.now(), false) do
      {:pull, "o", cursors} ->
        b = Puller.begin_pull(b, "o")
        t0 = Srv.now()
        ans = GenServer.call(srv, {:request, domain, cursors}, 60_000)
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

[domains, rate, secs] =
  case System.argv() do
    [] -> [1000, 1000, 10]
    args -> Enum.map(args, &String.to_integer/1)
  end

n_actors = 200
follow_per_actor = max(div(domains, 10), 1)
:rand.seed(:exsss, {1, 1, 1})

origin =
  Enum.reduce(1..n_actors, Origin.new(max_streams: 64, notify_quiet_ms: 1000), fn a, o ->
    for d <- Enum.take_random(1..domains, follow_per_actor), reduce: o do
      o -> Origin.follow(o, "d#{d}", "u#{a}")
    end
  end)

follows = origin.follows
{:ok, srv} = Srv.start_link(origin)
lag = :ets.new(:lag, [:public, :duplicate_bag, write_concurrency: true])

for d <- 1..domains do
  Recv.start(srv, "d#{d}", MapSet.to_list(Map.get(follows, "d#{d}", MapSet.new())), 5, lag)
end

ticker = spawn_link(fn -> Stream.repeatedly(fn -> Process.sleep(100); send(srv, :tick) end) |> Stream.run() end)

IO.puts("domains=#{domains} actors=#{n_actors} each followed by #{follow_per_actor} domains; #{rate} posts/s for #{secs}s, 64 stream slots")
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
      GenServer.call(srv, {:publish, "u#{a}", %{id: "p#{n}-#{:rand.uniform(1_000_000)}", type: :create, visibility: :public, at: Srv.now()}}, 60_000)
    end
    Process.sleep(max(target - Srv.now(), 0))
    n + per
  end)

IO.puts("posted #{posted} in #{Srv.now() - t0} ms (target #{secs * 1000})")
Process.sleep(10_000)
pct = fn xs, p -> xs |> Enum.sort() |> then(&Enum.at(&1, min(round(length(&1) * p) , length(&1) - 1))) end
get = fn k -> for {^k, v} <- :ets.tab2list(lag), do: v end
lags = get.(:lag)
calls = get.(:call_us)
expected =
  for {:posted, a} <- :ets.tab2list(lag), reduce: 0 do
    acc -> acc + Enum.count(follows, fn {_d, as} -> MapSet.member?(as, "u#{a}") end)
  end

IO.puts("expected deliveries=#{expected}")
IO.puts("server stats: #{inspect(GenServer.call(srv, :stats))}  peak mailbox=#{:atomics.get(peak_q, 1)}")
IO.puts("deliveries=#{length(lags)}  lag ms p50=#{pct.(lags, 0.5)} p99=#{pct.(lags, 0.99)} max=#{Enum.max(lags, fn -> 0 end)}")
IO.puts("pull call (request_stream round trip) ms p50=#{pct.(calls, 0.5)} p99=#{pct.(calls, 0.99)} max=#{Enum.max(calls, fn -> 0 end)}  calls=#{length(calls)}  declined=#{inspect(Enum.frequencies(get.(:declined)))}")
Process.exit(ticker, :kill); Process.exit(monitor, :kill)
