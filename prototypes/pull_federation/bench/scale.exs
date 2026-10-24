# SPDX-License-Identifier: AGPL-3.0-or-later
# Wall-clock cost of the real Origin/Puller code as the data grows.
# Run: mix run bench/scale.exs
alias PullFederation.{Origin, Puller}

defmodule B do
  def t(fun) do
    {us, r} = :timer.tc(fun)
    {us / 1000, r}
  end

  def ms(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)

  def mem(fun) do
    :erlang.garbage_collect()
    before = :erlang.memory(:total)
    r = fun.()
    :erlang.garbage_collect()
    {(:erlang.memory(:total) - before) / 1_048_576, r}
  end

  def build(actors, domains, per_actor) do
    :rand.seed(:exsss, {1, 2, 3})

    Enum.reduce(1..actors, Origin.new(max_streams: 1_000_000), fn a, o ->
      Enum.reduce(1..per_actor, o, fn _, o ->
        Origin.follow(o, "d#{:rand.uniform(domains)}", "u#{a}")
      end)
    end)
  end

  def post(o, a, i),
    do: elem(Origin.publish(o, "u#{a}", %{id: "#{a}-#{i}", type: :create, visibility: :public}), 0)
end

IO.puts("== 1. origin with N local actors (each followed by 5 of 1000 domains), 1 post each")

for n <- [1_000, 10_000, 100_000] do
  {mb, o} = B.mem(fn -> B.build(n, 1000, 5) end)
  {tp, o} = B.t(fn -> Enum.reduce(1..n, o, &B.post(&2, &1, 0)) end)
  {tn, {o, notes}} = B.t(fn -> Origin.due_notifications(o, 10_000) end)
  {ts, _} = B.t(fn -> Origin.request_stream(o, "d1", %{}, 20_000) end)
  {tb, _} = B.t(fn -> Origin.bucket_doc(o, PullFederation.Snapshot.bucket("u1")) end)

  IO.puts(
    "  actors=#{n}: state=#{B.ms(mb)} MB  publish=#{B.ms(tp / n * 1000)} us/post" <>
      "  due_notifications(#{length(notes)} domains)=#{B.ms(tn)} ms" <>
      "  request_stream(one domain)=#{B.ms(ts)} ms  bucket_doc=#{B.ms(tb)} ms"
  )
end

IO.puts("\n== 2. one hot actor, log length L, request from a caught-up and a fresh cursor")

for l <- [1_000, 10_000, 100_000] do
  o = B.build(1, 10, 10) |> Origin.follow("d1", "u1") |> Origin.follow("d2", "u1")
  {tp, o} = B.t(fn -> Enum.reduce(1..l, o, &B.post(&2, 1, &1)) end)
  fresh = %{}
  near = %{"u1" => PullFederation.Etag.ordered(l - 1)}
  {tf, _} = B.t(fn -> Origin.request_stream(o, "d1", fresh, 0) end)
  {tn, _} = B.t(fn -> Origin.request_stream(o, "d2", near, 0) end)

  IO.puts(
    "  L=#{l}: publish=#{B.ms(tp / l * 1000)} us/post  stream(fresh cursor)=#{B.ms(tf)} ms" <>
      "  stream(1 behind)=#{B.ms(tn)} ms"
  )
end

IO.puts("\n== 3. receiver: notifications and stream apply with many origins")

for n <- [100, 1_000, 10_000] do
  b =
    Enum.reduce(1..n, Puller.new(max_pending: 1_000_000), fn i, b ->
      Puller.follow(b, "o#{i}", "u#{i}")
    end)

  {tn, b} =
    B.t(fn ->
      Enum.reduce(1..n, b, fn i, b ->
        elem(Puller.notify(b, "o#{i}", %{"u#{i}" => PullFederation.Etag.ordered(1)}, 0), 0)
      end)
    end)

  {tp, _} =
    B.t(fn ->
      for i <- 1..n, reduce: b do
        b ->
          b = Puller.begin_pull(b, "o#{i}")
          ev = %{key: "u#{i}", etag: PullFederation.Etag.ordered(1), activity: %{id: "x#{i}", type: :create, visibility: :public}}
          Puller.finish_pull(b, "o#{i}", {:ok, [ev], %{"u#{i}" => PullFederation.Etag.ordered(1)}}, 1, fn _ -> 0 end)
      end
    end)

  IO.puts("  origins=#{n}: notify=#{B.ms(tn / n * 1000)} us each  pull cycle=#{B.ms(tp / n * 1000)} us each")
end

IO.puts("\n== 4. one very popular actor: followed by D domains, 100 posts in a burst")

for d <- [1_000, 10_000, 100_000] do
  o = Enum.reduce(1..d, Origin.new(max_streams: 1_000_000), &Origin.follow(&2, "d#{&1}", "ustar"))
  {tp, o} = B.t(fn -> Enum.reduce(1..100, o, &B.post(&2, "star", &1)) end)
  {tn, {_o, notes}} = B.t(fn -> Origin.due_notifications(o, 10_000) end)
  IO.puts("  D=#{d}: publish=#{B.ms(tp / 100)} ms/post (#{B.ms(tp / 100 * 1000 / d)} us per follower domain)  due_notifications=#{B.ms(tn)} ms for #{length(notes)} domains")
end
