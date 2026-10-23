# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Compare do
  @moduledoc """
  Runs the same workload through the push model and the pull model
  against one receiving instance B, in 100 ms ticks.

  B is the thing being protected. It has a budget of `cap_per_s` work
  units, a FIFO of incoming work with at most `max_queue` entries, and an
  optional outage window. Costs (the assumptions this whole comparison
  rests on; change them and re-run):

    * every HTTP request B accepts costs `request_cost` (default 1.0: TLS, signature check)
    * every database query B runs costs `db_query_cost` (default 0.5)
    * handling one activity in memory (parse, verify, classify) costs 0.5,
      plus 0.1 per row of a multi-row insert

  A push POST is one request plus two queries (dedupe lookup, insert).
  A pull stream of n activities is one request plus four queries for the
  whole batch (cursor read, batched dedupe, multi-row insert, cursor
  write), "pay once per batch" (docs/CODE_STYLE.md). A notification is one
  request and no query. Origin-side cost is in `PullFederation.FanOut`;
  here only B is scarce.
  """

  alias PullFederation.{Origin, PushOrigin, Puller}

  @tick 100
  @default_request_cost 1.0
  @activity_cost 0.5
  @row_cost 0.1
  @default_db_query_cost 0.5

  @doc "Deterministic workloads. `events` are `{t_ms, origin, actor_no, visibility}`."
  def scenarios do
    steady = for i <- 0..59, do: {i * 1_000, rem(i, 5), rem(i, 3), :public}
    # 20 origins, 25 activities each, inside 5 seconds
    burst =
      for o <- 0..19, i <- 0..24, do: {rem(i * 200 + o * 7, 5_000), o, rem(i, 5), :public}

    mixed =
      for {t, o, a, _} <- burst,
          do: {t, o, a, if(rem(t, 10) == 0, do: :direct, else: :public)}

    outage = for i <- 0..39, do: {i * 1_000, rem(i, 4), rem(i, 2), :public}

    [
      %{name: "steady: 1 post/s, 5 origins", origins: 5, events: steady, cap: 50, queue: 100},
      %{
        name: "burst: 20 origins x 25 posts in 5s",
        origins: 20,
        events: burst,
        cap: 50,
        queue: 100
      },
      %{name: "burst, 10% direct messages", origins: 20, events: mixed, cap: 50, queue: 100},
      %{
        name: "burst, cheap requests (request cost 0.2)",
        origins: 20,
        events: burst,
        cap: 50,
        queue: 100,
        request_cost: 0.2
      },
      %{
        name: "burst, B has 4x capacity",
        origins: 20,
        events: burst,
        cap: 200,
        queue: 100
      },
      %{
        name: "B down 10s-40s, 4 origins",
        origins: 4,
        events: outage,
        cap: 50,
        queue: 100,
        down: {10_000, 40_000}
      }
    ]
  end

  def run(model, sc) when model in [:push, :pull] do
    state = init(model, sc)
    last = sc.events |> Enum.map(&elem(&1, 0)) |> Enum.max()
    horizon = last + 120_000

    state = Enum.reduce(0..div(horizon, @tick), state, fn k, st -> tick(st, k * @tick) end)
    report(state, sc)
  end

  # --- state -------------------------------------------------------------

  defp init(model, sc) do
    actors = for o <- 0..(sc.origins - 1), a <- 0..4, do: {o, actor(o, a)}

    origins =
      for o <- 0..(sc.origins - 1), into: %{} do
        ao =
          Enum.reduce(actors, Origin.new(), fn
            {^o, actor}, acc -> Origin.follow(acc, "b", actor)
            _, acc -> acc
          end)

        {o, %{pull: ao, push: PushOrigin.new()}}
      end

    b =
      Enum.reduce(actors, Puller.new(), fn {o, actor}, acc ->
        Puller.follow(acc, "o#{o}", actor)
      end)

    %{
      model: model,
      sc: sc,
      origins: origins,
      b: b,
      queue: :queue.new(),
      qlen: 0,
      budget: 0.0,
      inflight: nil,
      published: %{},
      applied: %{},
      requests: 0,
      failed_requests: 0,
      lost_notes: 0,
      declines: 0,
      peak_rps: 0,
      second: %{},
      recovery_sent: false,
      next_id: 0
    }
  end

  defp qc(%{sc: sc}), do: Map.get(sc, :db_query_cost, @default_db_query_cost)

  defp rc(%{sc: sc}), do: Map.get(sc, :request_cost, @default_request_cost)

  defp actor(o, a), do: "https://o#{o}.example/users/u#{a}"

  # --- one tick ----------------------------------------------------------

  defp tick(st, now) do
    st
    |> publish_due(now)
    |> origins_send(now)
    |> recovery_broadcast(now)
    |> b_work(now)
    |> b_schedule_pull(now)
  end

  defp down?(%{sc: sc}, now) do
    case sc[:down] do
      {from, to} -> now >= from and now < to
      nil -> false
    end
  end

  defp publish_due(st, now) do
    events = Enum.filter(st.sc.events, fn {t, _, _, _} -> t >= now and t < now + @tick end)

    Enum.reduce(events, st, fn {_, o, a, vis}, st ->
      id = "act-#{st.next_id}"
      act = %{type: :create, id: id, visibility: vis}
      ao = actor(o, a)
      st = %{st | next_id: st.next_id + 1, published: Map.put(st.published, id, now)}
      publish_one(st, o, ao, act, now)
    end)
  end

  defp publish_one(%{model: :push} = st, o, ao, act, now) do
    _ = ao
    put_in(st.origins[o].push, PushOrigin.publish(st.origins[o].push, act, ["b"], now))
  end

  defp publish_one(%{model: :pull} = st, o, ao, act, now) do
    case Origin.publish(st.origins[o].pull, ao, act) do
      {pull, {:pull, _}} ->
        put_in(st.origins[o].pull, pull)

      {pull, :push_only} ->
        st = put_in(st.origins[o].pull, pull)
        put_in(st.origins[o].push, PushOrigin.publish(st.origins[o].push, act, ["b"], now))
    end
  end

  defp origins_send(st, now) do
    Enum.reduce(Map.keys(st.origins), st, fn o, st ->
      st |> send_push_jobs(o, now) |> send_notifications(o, now)
    end)
  end

  defp send_push_jobs(st, o, now) do
    {po, jobs} = PushOrigin.due(st.origins[o].push, now)
    st = put_in(st.origins[o].push, po)

    Enum.reduce(jobs, st, fn job, st ->
      case accept(st, now, {:push, job}, rc(st) + @activity_cost + 2 * qc(st)) do
        {:ok, st} ->
          st

        {:error, st} ->
          put_in(st.origins[o].push, PushOrigin.result(st.origins[o].push, job, :fail, now))
      end
    end)
  end

  defp send_notifications(%{model: :push} = st, _o, _now), do: st

  defp send_notifications(%{model: :pull} = st, o, now) do
    {pull, notes} = Origin.due_notifications(st.origins[o].pull, now)
    st = put_in(st.origins[o].pull, pull)

    Enum.reduce(notes, st, fn {"b", announced}, st ->
      deliver_note(st, o, announced, now)
    end)
  end

  defp deliver_note(st, o, announced, now) do
    case accept(st, now, {:notify, o, announced}, rc(st)) do
      {:ok, st} -> st
      {:error, st} -> %{st | lost_notes: st.lost_notes + 1}
    end
  end

  # "Server Status Broadcast": when B comes back, each origin tells it, spread by jitter.
  defp recovery_broadcast(%{model: :pull, sc: %{down: {_, to}}, recovery_sent: false} = st, now)
       when now >= to do
    st =
      Enum.reduce(Map.keys(st.origins), st, fn o, st ->
        jitter = :erlang.phash2(o, 20_000)
        update_in(st.recovery_sent, fn _ -> true end) |> schedule_recovery(o, to + jitter)
      end)

    st
  end

  defp recovery_broadcast(%{model: :pull} = st, now) do
    due = Map.get(st, :recoveries, [])
    {ready, rest} = Enum.split_with(due, fn {_, t} -> t <= now end)
    st = Map.put(st, :recoveries, rest)

    Enum.reduce(ready, st, fn {o, _}, st ->
      [{_, "b", announced}] = Origin.recovered(st.origins[o].pull, fn _ -> 0 end)
      deliver_note(st, o, announced, now)
    end)
  end

  defp recovery_broadcast(st, _now), do: st

  defp schedule_recovery(st, o, t), do: Map.update(st, :recoveries, [{o, t}], &[{o, t} | &1])

  # --- B ------------------------------------------------------------------

  # Single admission point for everything that reaches B.
  defp accept(st, now, item, cost) do
    st = count_request(st, now)

    cond do
      down?(st, now) -> {:error, %{st | failed_requests: st.failed_requests + 1}}
      st.qlen >= st.sc.queue -> {:error, %{st | failed_requests: st.failed_requests + 1}}
      true -> {:ok, %{st | queue: :queue.in({item, cost}, st.queue), qlen: st.qlen + 1}}
    end
  end

  defp count_request(st, now) do
    sec = div(now, 1_000)
    n = Map.get(st.second, sec, 0) + 1

    %{
      st
      | requests: st.requests + 1,
        second: Map.put(st.second, sec, n),
        peak_rps: max(st.peak_rps, n)
    }
  end

  defp b_work(st, now) do
    budget = if down?(st, now), do: 0.0, else: st.sc.cap * @tick / 1_000
    drain(%{st | budget: budget}, now)
  end

  defp drain(%{budget: b} = st, _now) when b <= 0.0, do: st

  defp drain(st, now) do
    case :queue.out(st.queue) do
      {:empty, _} ->
        st

      {{:value, {item, cost}}, rest} ->
        case cost <= st.budget do
          true ->
            st = %{st | queue: rest, qlen: st.qlen - 1, budget: st.budget - cost}
            drain(complete(st, item, now), now)

          false ->
            st = %{st | queue: :queue.in_r({item, cost - st.budget}, rest), budget: 0.0}
            st
        end
    end
  end

  defp complete(st, {:push, job}, now) do
    b = Puller.apply_activity(st.b, job.activity, now)
    %{st | b: b, applied: Map.put_new(st.applied, job.activity.id, now)}
  end

  defp complete(st, {:notify, o, announced}, now) do
    {b, _} = Puller.notify(st.b, "o#{o}", announced, now)
    %{st | b: b}
  end

  defp complete(st, {:stream, o, events, announced}, now) do
    b = Puller.finish_pull(st.b, "o#{o}", {:ok, events, announced}, now, &jitter/1)
    pull = Origin.close_stream(st.origins[o].pull)

    applied =
      Enum.reduce(events, st.applied, fn %{activity: %{id: id}}, acc ->
        Map.put_new(acc, id, now)
      end)

    st = put_in(st.origins[o].pull, pull)
    %{st | b: b, applied: applied, inflight: nil}
  end

  defp jitter(max), do: :erlang.phash2(max, max + 1)

  defp b_schedule_pull(%{model: :push} = st, _now), do: st

  defp b_schedule_pull(%{inflight: nil} = st, now) do
    busy? = st.qlen > 0 or down?(st, now)

    case Puller.next_pull(st.b, now, busy?) do
      {:pull, "o" <> n, cursors} ->
        o = String.to_integer(n)
        st = count_request(st, now)

        case Origin.open_stream(st.origins[o].pull, "b", cursors, now) do
          {:ok, pull, events, announced} ->
            st = put_in(st.origins[o].pull, pull)
            cost = rc(st) + 4 * qc(st) + length(events) * (@activity_cost + @row_cost)
            item = {:stream, o, events, announced}
            %{st | queue: :queue.in({item, cost}, st.queue), qlen: st.qlen + 1, inflight: o}

          {:error, _} = err ->
            b = Puller.finish_pull(st.b, "o#{o}", err, now, &jitter/1)
            %{st | b: b, declines: st.declines + 1}
        end

      _ ->
        st
    end
  end

  defp b_schedule_pull(st, _now), do: st

  # --- report ---------------------------------------------------------------

  defp report(st, sc) do
    expected = sc.events |> length()
    lat = for {id, t} <- st.applied, pub = st.published[id], do: t - pub
    lat = Enum.sort(lat)

    push_sent = st.origins |> Map.values() |> Enum.map(& &1.push.sent) |> Enum.sum()
    dropped = st.origins |> Map.values() |> Enum.map(& &1.push.dropped) |> Enum.sum()

    %{
      model: st.model,
      delivered: "#{length(lat)}/#{expected}",
      requests_to_b: st.requests,
      failed_requests: st.failed_requests,
      peak_requests_per_s: st.peak_rps,
      push_posts: push_sent,
      give_ups: dropped,
      lost_notifications: st.lost_notes,
      pull_declines: st.declines,
      latency_p50_ms: percentile(lat, 0.5),
      latency_p99_ms: percentile(lat, 0.99),
      latency_max_ms: List.last(lat)
    }
  end

  defp percentile([], _), do: nil

  defp percentile(sorted, p),
    do: Enum.at(sorted, min(length(sorted) - 1, round(p * (length(sorted) - 1))))
end
