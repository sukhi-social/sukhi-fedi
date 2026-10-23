# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Origin do
  @moduledoc """
  Instance A. Pure state machine; every function takes `now` (ms).

  Responsibilities:

    * `publish/3`     assign per-actor sequence ids to pullable activities
    * `due_notifications/2`  step 2 + 9: coalesce, then notify at most once
      per `notify_quiet_ms` per remote domain
    * `open_stream/4` steps 6-7: admit or decline, then yield what the
      remote's followed actors have beyond its cursors
    * `close_stream/1`
    * `recovered/2`   "Server Status Broadcast": notify everyone, spread by jitter
  """

  alias PullFederation.Visibility

  defstruct log: %{},
            seqs: %{},
            followers: %{},
            dirty: %{},
            last_notified: %{},
            active_streams: 0,
            max_streams: 4,
            notify_quiet_ms: 3_000,
            decline_retry_ms: 5_000

  @type event :: %{actor: String.t(), seq: pos_integer, activity: map}

  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @doc "Record that `domain` follows `actor` (shared-inbox granularity)."
  def follow(%__MODULE__{} = o, domain, actor) do
    %{
      o
      | followers: Map.update(o.followers, actor, MapSet.new([domain]), &MapSet.put(&1, domain))
    }
  end

  @doc """
  Append an activity. Pullable ones get the actor's next seq; direct
  messages return `:push_only` and leave the sequence untouched, so a
  gap never means "a secret exists".
  """
  def publish(%__MODULE__{} = o, actor, %{visibility: vis} = activity) do
    case Visibility.pullable?(vis) do
      false ->
        {o, :push_only}

      true ->
        seq = Map.get(o.seqs, actor, 0) + 1
        event = %{actor: actor, seq: seq, activity: activity}
        domains = Map.get(o.followers, actor, MapSet.new())

        dirty =
          Enum.reduce(domains, o.dirty, fn d, acc ->
            Map.update(acc, d, MapSet.new([actor]), &MapSet.put(&1, actor))
          end)

        log = Map.update(o.log, actor, [event], &[event | &1])
        {%{o | log: log, seqs: Map.put(o.seqs, actor, seq), dirty: dirty}, {:pull, seq}}
    end
  end

  @doc "Notifications whose quiet period has elapsed: `[{domain, announced_seqs}]`."
  def due_notifications(%__MODULE__{} = o, now) do
    {due, _held} =
      Enum.split_with(o.dirty, fn {domain, _} ->
        now - Map.get(o.last_notified, domain, -o.notify_quiet_ms) >= o.notify_quiet_ms
      end)

    msgs = for {domain, _actors} <- due, do: {domain, announced_for(o, domain)}

    o = %{
      o
      | dirty: Map.drop(o.dirty, Enum.map(due, &elem(&1, 0))),
        last_notified:
          Enum.reduce(due, o.last_notified, fn {d, _}, acc -> Map.put(acc, d, now) end)
    }

    {o, Enum.sort(msgs)}
  end

  @doc """
  Decline when busy, otherwise reserve a slot and return the events the
  remote is missing. The caller must `close_stream/1` when done.
  """
  def open_stream(%__MODULE__{} = o, domain, cursors, _now) do
    case o.active_streams < o.max_streams do
      false ->
        {:error, {:busy, o.decline_retry_ms}}

      true ->
        events = events_for(o, domain, cursors)
        {:ok, %{o | active_streams: o.active_streams + 1}, events, announced_for(o, domain)}
    end
  end

  def close_stream(%__MODULE__{active_streams: n} = o) when n > 0,
    do: %{o | active_streams: n - 1}

  @doc "Recovery broadcast to every domain that follows anyone here; `jitter.(domain)` is the delay in ms."
  def recovered(%__MODULE__{} = o, jitter) do
    domains = o.followers |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    for d <- Enum.sort(domains), do: {jitter.(d), d, announced_for(o, d)}
  end

  defp announced_for(o, domain) do
    for {actor, domains} <- o.followers,
        MapSet.member?(domains, domain),
        seq = o.seqs[actor],
        into: %{} do
      {actor, seq}
    end
  end

  defp events_for(o, domain, cursors) do
    for {actor, announced} <- announced_for(o, domain),
        announced > Map.get(cursors, actor, 0),
        event <- Enum.reverse(Map.fetch!(o.log, actor)),
        event.seq > Map.get(cursors, actor, 0) do
      event
    end
  end
end
