# SPDX-License-Identifier: AGPL-3.0-or-later
# Questions the design raises, asked on a store of its own:
#   MIX_ENV=test mix run script/probe.exs        (HOSI_REAL=1 for the real engine)
import Ecto.Query
alias CoreViews.{Note, Repo}

defmodule Probe.TupleBoost do
  # the boost rule as sukhi declares it today: a hosigraph tuple over actor and object
  use Ecto.Schema
  use Ecto.Hosi.View
  hosi_where type: "announce"
  hosi_owner :account_id
  hosi_unique [:account_id, :note_id], tuple: true

  schema "boosts" do
    hosi_attributes CoreViews.ActivityPub, type: :type, account_id: :actor, note_id: :object
  end
end

dir = Path.join(System.tmp_dir!(), "core_views_probe_#{System.os_time()}")

backend =
  if System.get_env("HOSI_REAL"),
    do: [khana: [jvm: System.fetch_env!("HOSI_JAR"), java: System.get_env("HOSI_JAVA", "java")]],
    else: [hosi: Ecto.Hosi.Fake]

start = fn name, views ->
  {:ok, pid} = Repo.start_link([dir: Path.join(dir, name), schemas: views] ++ backend)
  pid
end

try_ = fn label, fun ->
  result =
    try do
      inspect(fun.(), limit: 8, printable_limit: 200)
    rescue
      e -> "raised: " <> String.slice(Exception.message(e), 0, 400)
    end

  IO.puts("#{label}\n    #{result}")
end

ms = fn fun ->
  times = for _ <- 1..5, do: elem(:timer.tc(fun), 0)
  "#{Float.round(Enum.at(Enum.sort(times), 2) / 1000, 1)} ms (median of 5)"
end

IO.puts("== 1. a tuple rule over shared attributes")
views = [Probe.TupleBoost | Repo.views() -- [CoreViews.Boost]]
pid = start.("tuple", views)

try_.("a follow (has actor and object)", fn ->
  Repo.insert!(%CoreViews.Follow{follower_id: 3, follower_uri: "u", followee_id: 2}).id
end)

try_.("a note (neither)", fn -> Repo.insert!(%Note{account_id: 2, content: "a"}).id end)
note = Repo.one!(from n in Note, limit: 1)
react = fn e -> %CoreViews.Reaction{account_id: 3, note_id: note.id, emoji: e} |> Repo.insert!() end
try_.("first reaction", fn -> react.("a").id end)
try_.("second reaction, other emoji", fn -> react.("b").id end)
Supervisor.stop(pid)

IO.puts("== 2. many-valued facts")
pid = start.("main", Repo.views())
n = Repo.insert!(%Note{account_id: 2, content: "a", media_ids: [901, 900], tags: ["b", "a"]})

try_.("media ids and tags read back", fn ->
  m = Repo.get!(Note, n.id)
  {m.media_ids, m.tags}
end)

IO.puts("== 3. EXISTS note_media in plain Ecto")
Repo.insert!(%Note{account_id: 2, content: "no media"})

try_.("where not is_nil(n.media_ids)", fn ->
  Repo.all(from x in Note, where: not is_nil(x.media_ids), select: x.id)
end)

try_.("where is_nil(n.media_ids)", fn ->
  Repo.all(from x in Note, where: is_nil(x.media_ids), select: x.id)
end)

try_.("its explain", fn ->
  Repo.explain(from x in Note, where: x.id in ^[n.id] and not is_nil(x.media_ids))
end)

IO.puts("== 4. what the timeline queries become")

try_.("public", fn ->
  Repo.explain(
    from x in Note,
      where: x.visibility == "public" and is_nil(x.domain),
      order_by: [desc: x.id],
      limit: 20
  )
end)

Supervisor.stop(pid)

if System.get_env("PROBE_SIZE") do
  size = String.to_integer(System.get_env("PROBE_SIZE"))
  IO.puts("== 5. sizes: #{size} public notes by 100 authors; home of someone who follows 50")
  pid = start.("size", Repo.views())
  now = DateTime.utc_now(:second)

  insert = fn view, rows ->
    rows
    |> Enum.chunk_every(2_000)
    |> Enum.each(&Repo.insert_all(view, &1, timeout: 120_000))
  end

  insert.(Note, for(i <- 1..size, do: %{account_id: 2 + rem(i, 100), content: "n#{i}", visibility: "public", created_at: now}))
  follower_uri = "https://here.test/users/1000"

  for a <- 2..51 do
    Repo.insert!(%CoreViews.Follow{follower_id: 1000, follower_uri: follower_uri, followee_id: a, state: "accepted"})
  end

  some = Repo.all(from x in Note, where: x.account_id == 2, select: x.id)
  insert.(CoreViews.Boost, for(id <- Enum.take(some, 5), do: %{account_id: 3, note_id: id, created_at: now}))

  boosts = fn -> Repo.highest_in(CoreViews.Boost, {:account_id, :created_at}, [3], 40) end
  opts = [reply_here: "https://here.test/%"]
  IO.puts("public, query + order_by: " <> ms.(fn -> CoreViews.Timelines.public() end))

  IO.puts(
    "public, Repo.highest walk: " <>
      ms.(fn -> Repo.highest(:"ap/registered-at", 100, load: Note) end)
  )

  IO.puts("home: " <> ms.(fn -> CoreViews.Timelines.home(1000, follower_uri, opts) end))

  IO.puts(
    "home, only_media: " <>
      ms.(fn -> CoreViews.Timelines.home(1000, follower_uri, opts ++ [only_media: true]) end)
  )

  IO.puts(
    "home, keyword gate on 50: " <>
      ms.(fn ->
        CoreViews.Timelines.home(1000, follower_uri, opts ++ [keywords: [{Enum.to_list(2..51), "n1"}]])
      end)
  )

  IO.puts("one account's 5 boosts, before its reactions: " <> ms.(boosts))
  ids = Repo.all(from x in Note, select: x.id)

  # reactions share `ap/actor` + `ap/registered-at`, so they sit in the boosts' index
  insert.(
    CoreViews.Reaction,
    for(id <- Enum.take(ids, div(size, 2)), do: %{account_id: 3, note_id: id, emoji: "a", created_at: DateTime.add(now, 60)})
  )

  try_.("... boosts found", fn -> length(boosts.()) end)
  IO.puts("the same after #{div(size, 2)} newer reactions of that account: " <> ms.(boosts))
  Supervisor.stop(pid)
end

File.rm_rf!(dir)
