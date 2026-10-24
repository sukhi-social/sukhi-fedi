# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.NotifyCost do
  @moduledoc """
  Inline sequences vs bucket snapshots, counted on the real `Origin` /
  `Puller` logic.

  A hosts `actors` actors; each of `domains` remote domains follows
  `follow_k` of them (seeded, deterministic). `posts` activities by random
  followed actors arrive over `window_ms`. We count what each notification
  weighs on the wire, and, for snapshots, what B then fetches and how
  often A has to *render* a bucket document (once per bucket version,
  the rest are cache hits).

  Sizes are bytes of the JSON-ish payload: key length + token length per inline
  entry, 12 per bucket version, 72 per snapshot entry (64-char hash + seq).
  """

  alias PullFederation.{Origin, Snapshot}

  @tick 100
  @envelope 200

  def run(inline_max, opts \\ []) do
    p =
      Map.merge(
        %{
          actors: 2_000,
          domains: 200,
          follow_k: 100,
          posts: 200,
          window_ms: 10_000,
          quiet_ms: 3_000
        },
        Map.new(opts)
      )

    :rand.seed(:exsss, {1, 2, 3})
    uris = for i <- 1..p.actors, do: "https://a.example/users/u#{i}"

    follows =
      for d <- 1..p.domains, into: %{} do
        {"d#{d}", uris |> Enum.take_random(p.follow_k) |> MapSet.new()}
      end

    o0 =
      Enum.reduce(follows, Origin.new(inline_max: inline_max, notify_quiet_ms: p.quiet_ms), fn
        {d, set}, acc -> Enum.reduce(set, acc, &Origin.follow(&2, d, &1))
      end)

    followed_by_anyone =
      follows |> Map.values() |> Enum.reduce(&MapSet.union/2) |> MapSet.to_list()

    gap = div(p.window_ms, p.posts)

    {origin, stats} =
      Enum.reduce(0..div(p.window_ms + p.quiet_ms, @tick), {o0, new_stats()}, fn k, {o, st} ->
        now = k * @tick

        o =
          case rem(now, gap) == 0 and div(now, gap) < p.posts do
            true ->
              actor = Enum.random(followed_by_anyone)
              elem(Origin.publish(o, actor, %{id: "a#{now}", visibility: :public}), 0)

            false ->
              o
          end

        {o, notes} = Origin.due_notifications(o, now)
        {o, Enum.reduce(notes, st, &account(&2, &1, follows, o))}
      end)

    _ = origin

    %{
      inline_max: inline_max,
      notifications: stats.notes,
      notification_bytes: stats.note_bytes,
      avg_notification_bytes: div(stats.note_bytes, max(stats.notes, 1)),
      snapshot_fetches: stats.fetches,
      snapshot_bytes: stats.fetch_bytes,
      origin_renders: MapSet.size(stats.renders),
      total_wire_bytes: stats.note_bytes + stats.fetch_bytes
    }
  end

  defp new_stats,
    do: %{notes: 0, note_bytes: 0, fetches: 0, fetch_bytes: 0, renders: MapSet.new()}

  defp account(st, {domain, inline}, _follows, _o) when is_map(inline) do
    bytes = @envelope + Enum.sum(for {k, v} <- inline, do: byte_size(k) + byte_size(v))
    _ = domain
    %{st | notes: st.notes + 1, note_bytes: st.note_bytes + bytes}
  end

  defp account(st, {domain, {:buckets, versions, followers}}, follows, o) do
    bytes =
      @envelope + 12 * map_size(versions) +
        Enum.sum(for {k, v} <- followers, do: byte_size(k) + byte_size(v))

    mine = follows |> Map.fetch!(domain) |> MapSet.new(&Snapshot.bucket/1)

    wanted = for {b, v} <- versions, MapSet.member?(mine, b), do: {b, v}

    docs =
      for {b, v} <- wanted do
        {{b, v}, map_size(Origin.bucket_doc(o, b).entries) * 72}
      end

    %{
      st
      | notes: st.notes + 1,
        note_bytes: st.note_bytes + bytes,
        fetches: st.fetches + length(docs),
        fetch_bytes: st.fetch_bytes + Enum.sum(Enum.map(docs, &elem(&1, 1))),
        renders: Enum.reduce(docs, st.renders, fn {key, _}, acc -> MapSet.put(acc, key) end)
    }
  end
end
