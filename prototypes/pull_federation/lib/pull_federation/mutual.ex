# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Mutual do
  @moduledoc """
  Two servers, each both an origin and a receiver, that follow each other
  and are both busy at the same time: can they get stuck?

  A node has `workers` units of capacity. A stream it serves holds one for
  the stream's length; a pull it makes holds one from the moment the
  request is sent until the answer comes back. With `shared: true` both
  kinds draw from the same units (the naive implementation, one worker
  pool); `reserve` units are kept for serving, so an outgoing pull may
  only start while `used < workers - reserve`.

  Waits that could form a cycle: A's pull waits for an answer from B, and
  B's answer needs a worker that B's own pull is holding while it waits
  for A. The protocol turns every wait into an immediate refusal
  (`{:busy, ms}` / `{:retry_at, ms}`), so what is left to check is
  *livelock*: both sides refuse each other again and again at the same
  moments. `run/1` measures whether everything is delivered after the load
  stops and the busy windows end, and how long that takes.

  Knobs (all in ms): `workers`, `shared`, `reserve`, `stream_ms`,
  `rtt_ms`, `post_every_ms`, `post_until_ms`, `until_ms`, `busy` (windows
  where a node starts no pulls and refuses everything it is asked),
  `stall` (this many streams per node are never read: the receiver hangs),
  `stream_timeout_ms` (origin side), `pull_timeout_ms` (receiver side),
  `jitter` (`:none | :same | :random`, what the receivers add to a backoff),
  `tie_break` (shared pool full and this node is itself waiting on the
  requester: the node with the greater name drops its own pull and serves).
  """

  alias PullFederation.{Origin, Puller}

  @tick 10
  @defaults %{
    workers: 4,
    shared: false,
    reserve: 0,
    stream_ms: 300,
    rtt_ms: 100,
    post_every_ms: 200,
    post_until_ms: 20_000,
    until_ms: 180_000,
    busy: [],
    stall: 0,
    stream_timeout_ms: 30_000,
    pull_timeout_ms: 10_000,
    jitter: :random,
    tie_break: false
  }

  def run(opts \\ []) do
    p = Map.merge(@defaults, Map.new(opts))
    :rand.seed(:exsss, {3, 1, Map.get(p, :seed, 4)})
    st = %{p: p, nodes: %{"a" => node("a", p), "b" => node("b", p)}, ev: :gb_sets.empty(), n: 0}
    st = loop(st, 0)
    report(st)
  end

  defp peer("a"), do: "b"
  defp peer("b"), do: "a"

  defp node(name, p) do
    other = peer(name)

    origin =
      Origin.new(
        max_streams: p.workers,
        stream_timeout_ms: p.stream_timeout_ms,
        calendar: [slot_ms: round(p.stream_ms / p.workers / 0.8)]
      )
      |> Origin.follow(other, actor(name))

    puller = Puller.new() |> Puller.follow(other, actor(other))

    %{
      name: name,
      origin: origin,
      puller: puller,
      out: nil,
      token: 0,
      stalls_left: p.stall,
      posted: 0,
      seen: MapSet.new(),
      requests: 0,
      refused: 0,
      timeouts: 0,
      last_delivery: 0
    }
  end

  defp actor(name), do: "actor@" <> name

  defp loop(st, t) when t > st.p.until_ms, do: st

  defp loop(st, t) do
    st = run_events(st, t)
    order = Enum.shuffle(["a", "b"])
    st = Enum.reduce(order, st, &tick_node(&2, &1, t))
    loop(st, t + @tick)
  end

  defp schedule(st, at, event) do
    %{st | ev: :gb_sets.add({at, st.n, event}, st.ev), n: st.n + 1}
  end

  defp run_events(st, t) do
    case :gb_sets.is_empty(st.ev) do
      true ->
        st

      false ->
        {at, _, event} = item = :gb_sets.smallest(st.ev)

        case at <= t do
          false -> st
          true -> run_events(handle(%{st | ev: :gb_sets.delete(item, st.ev)}, at, event), t)
        end
    end
  end

  defp half(st), do: div(st.p.rtt_ms, 2)

  defp busy?(p, t), do: Enum.any?(p.busy, fn {from, to} -> t >= from and t < to end)

  defp used(n), do: n.origin.active_streams + if(n.out, do: 1, else: 0)

  # ---- per-tick work of one node ----

  defp tick_node(st, name, t) do
    n = st.nodes[name]
    st = put_node(st, %{n | origin: Origin.reap(n.origin, t)})
    st |> post(name, t) |> notify(name, t) |> pull(name, t) |> pull_timeout(name, t)
  end

  defp post(st, name, t) do
    p = st.p

    case t < p.post_until_ms and rem(t, p.post_every_ms) == 0 do
      false ->
        st

      true ->
        n = st.nodes[name]
        id = "#{name}-#{n.posted}"
        act = %{id: id, type: :create, visibility: :public}
        {origin, _} = Origin.publish(n.origin, actor(name), act)
        put_node(st, %{n | origin: origin, posted: n.posted + 1})
    end
  end

  defp notify(st, name, t) do
    n = st.nodes[name]
    {origin, notes} = Origin.due_notifications(n.origin, t)
    st = put_node(st, %{n | origin: origin})

    Enum.reduce(notes, st, fn {_domain, ann}, acc ->
      schedule(acc, t + half(acc), {:notify, peer(name), name, ann})
    end)
  end

  defp pull(st, name, t) do
    n = st.nodes[name]
    p = st.p
    other = peer(name)

    capacity? = not p.shared or used(n) < p.workers - p.reserve
    busy = busy?(p, t) or not capacity?

    case n.out == nil and Puller.next_pull(n.puller, t, busy) do
      {:pull, ^other, cursors} ->
        puller = Puller.begin_pull(n.puller, other)
        token = n.token + 1

        n = %{
          n
          | puller: puller,
            out: %{token: token, start: t},
            token: token,
            requests: n.requests + 1
        }

        st
        |> put_node(n)
        |> schedule(t + half(st), {:req, other, name, cursors, token, t})

      _ ->
        st
    end
  end

  defp pull_timeout(st, name, t) do
    n = st.nodes[name]

    case n.out do
      %{start: s} when t - s > st.p.pull_timeout_ms ->
        puller =
          Puller.finish_pull(n.puller, peer(name), {:error, {:busy, 1_000}}, t, jitter_fun(st.p))

        put_node(st, %{n | puller: puller, out: nil, timeouts: n.timeouts + 1})

      _ ->
        st
    end
  end

  # ---- events ----

  defp handle(st, at, {:notify, to, from, ann}) do
    n = st.nodes[to]
    {puller, _} = Puller.notify(n.puller, from, ann, at)
    put_node(st, %{n | puller: puller})
  end

  # a request arrives at the serving node
  defp handle(st, at, {:req, server, client, cursors, token, _sent}) do
    s = st.nodes[server]
    s = %{s | origin: Origin.reap(s.origin, at)}
    p = st.p

    {s, yielded?} = maybe_yield(st, s, client, at)
    st = if yielded?, do: put_node(st, s), else: st

    {origin, answer} =
      cond do
        busy?(p, at) ->
          {s.origin, {:error, {:busy, 1_000}}}

        p.shared and used(s) >= p.workers ->
          {s.origin, {:error, {:busy, 500}}}

        true ->
          Origin.request_stream(s.origin, client, cursors, at)
      end

    s = %{s | origin: origin}
    st = put_node(st, s)

    case answer do
      {:ok, _, _} ->
        c = st.nodes[client]

        case c.stalls_left > 0 do
          # the receiver hangs: it never reads, never closes, never hears the end
          true ->
            put_node(st, %{c | stalls_left: c.stalls_left - 1})

          false ->
            st
            |> schedule(at + p.stream_ms, {:close, server, client})
            |> schedule(at + p.stream_ms + half(st), {:resp, client, server, answer, token, at})
        end

      {:error, _} ->
        s = %{s | refused: s.refused + 1}
        st = put_node(st, s)
        schedule(st, at + half(st), {:resp, client, server, answer, token, at})
    end
  end

  defp handle(st, at, {:close, server, client}) do
    s = st.nodes[server]
    put_node(st, %{s | origin: Origin.close_stream(s.origin, client, at)})
  end

  defp handle(st, at, {:resp, client, server, answer, token, _}) do
    c = st.nodes[client]

    case c.out do
      %{token: ^token} ->
        puller = Puller.observe_rtt(c.puller, server, st.p.rtt_ms)
        puller = Puller.finish_pull(puller, server, answer, at, jitter_fun(st.p))
        c = %{c | puller: puller, out: nil}
        put_node(st, record(c, answer, at))

      _ ->
        # we gave up on this pull already
        st
    end
  end

  # Symmetry breaker for a shared pool: two nodes each holding their last
  # worker for a pull of the other would refuse each other for ever. The
  # one with the greater name gives up its pull and serves instead.
  defp maybe_yield(st, s, client, at) do
    full? = st.p.shared and used(s) >= st.p.workers

    case st.p.tie_break and full? and s.out != nil and s.name > client and not busy?(st.p, at) do
      false ->
        {s, false}

      true ->
        puller =
          Puller.finish_pull(s.puller, client, {:error, {:busy, 100}}, at, jitter_fun(st.p))

        {%{s | puller: puller, out: nil}, true}
    end
  end

  defp record(c, {:ok, events, _}, at) do
    seen = Enum.reduce(events, c.seen, fn %{activity: %{id: id}}, s -> MapSet.put(s, id) end)
    %{c | seen: seen, last_delivery: at}
  end

  defp record(c, _, _), do: c

  defp jitter_fun(%{jitter: :none}), do: fn _ -> 0 end
  defp jitter_fun(%{jitter: :same}), do: fn max -> :erlang.phash2(max, max + 1) end
  defp jitter_fun(%{jitter: :random}), do: fn max -> :rand.uniform(max + 1) - 1 end

  defp put_node(st, n), do: %{st | nodes: Map.put(st.nodes, n.name, n)}

  defp report(st) do
    a = st.nodes["a"]
    b = st.nodes["b"]
    got_b = MapSet.size(b.seen)
    got_a = MapSet.size(a.seen)

    %{
      a_to_b: "#{got_b}/#{a.posted}",
      b_to_a: "#{got_a}/#{b.posted}",
      complete: got_b == a.posted and got_a == b.posted,
      last_delivery_ms: max(a.last_delivery, b.last_delivery),
      requests: a.requests + b.requests,
      refused: a.refused + b.refused,
      timeouts: a.timeouts + b.timeouts,
      reaped: a.origin.reaped + b.origin.reaped,
      slots_left: a.origin.active_streams + b.origin.active_streams
    }
  end
end
