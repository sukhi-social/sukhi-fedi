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

  alias PullFederation.{Snapshot, Visibility}

  defstruct log: %{},
            seqs: %{},
            followers: %{},
            dirty: %{},
            last_notified: %{},
            active_streams: 0,
            max_streams: 4,
            notify_quiet_ms: 3_000,
            decline_retry_ms: 5_000,
            bucket_versions: %{},
            inline_max: 5

  @type event :: %{actor: String.t(), key: String.t(), seq: pos_integer, activity: map}

  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @doc "Record that `domain` follows `actor` (shared-inbox granularity)."
  def follow(%__MODULE__{} = o, domain, actor) do
    %{
      o
      | followers: Map.update(o.followers, actor, MapSet.new([domain]), &MapSet.put(&1, domain))
    }
  end

  @doc """
  Append an activity. It takes the next seq of its index (public or
  followers-only, see `Visibility`); direct messages return `:push_only`
  and touch no sequence.
  """
  def publish(%__MODULE__{} = o, actor, %{visibility: vis} = activity) do
    case Visibility.index(vis) do
      nil ->
        {o, :push_only}

      index ->
        key = Visibility.key(actor, index)
        seq = Map.get(o.seqs, key, 0) + 1
        event = %{actor: actor, key: key, seq: seq, activity: activity}
        domains = Map.get(o.followers, actor, MapSet.new())

        dirty =
          Enum.reduce(domains, o.dirty, fn d, acc ->
            Map.update(acc, d, MapSet.new([key]), &MapSet.put(&1, key))
          end)

        log = Map.update(o.log, key, [event], &[event | &1])
        # actors nobody follows remotely never bump a bucket: nothing to tell anyone
        versions = bump_bucket(o.bucket_versions, actor, index, domains)

        {%{
           o
           | log: log,
             seqs: Map.put(o.seqs, key, seq),
             dirty: dirty,
             bucket_versions: versions
         }, {:pull, seq}}
    end
  end

  defp bump_bucket(versions, actor, :public, domains) do
    case MapSet.size(domains) do
      0 -> versions
      _ -> Map.update(versions, Snapshot.bucket(actor), 1, &(&1 + 1))
    end
  end

  defp bump_bucket(versions, _actor, :followers, _domains), do: versions

  @doc """
  Notifications whose quiet period has elapsed: `[{domain, notification}]`.

  A notification is either the changed sequences inline (`%{key => seq}`,
  when at most `inline_max` public actors changed), or
  `{:buckets, %{bucket => version}, inline_followers}` pointing at the
  snapshot buckets to fetch. Followers-only counters are always inline.
  """
  def due_notifications(%__MODULE__{} = o, now) do
    {due, _held} =
      Enum.split_with(o.dirty, fn {domain, _} ->
        now - Map.get(o.last_notified, domain, -o.notify_quiet_ms) >= o.notify_quiet_ms
      end)

    msgs = for {domain, dirty} <- due, do: {domain, notification(o, domain, dirty)}

    o = %{
      o
      | dirty: Map.drop(o.dirty, Enum.map(due, &elem(&1, 0))),
        last_notified:
          Enum.reduce(due, o.last_notified, fn {d, _}, acc -> Map.put(acc, d, now) end)
    }

    {o, Enum.sort(msgs)}
  end

  defp notification(o, domain, dirty) do
    changed = Map.take(announced_for(o, domain), MapSet.to_list(dirty))
    {public, followers} = Enum.split_with(changed, fn {key, _} -> Snapshot.public_key?(key) end)

    case length(public) <= o.inline_max do
      true ->
        changed

      false ->
        buckets =
          for {key, _} <- public, into: %{} do
            b = Snapshot.bucket(Visibility.actor_of(key))
            {b, Map.fetch!(o.bucket_versions, b)}
          end

        {:buckets, buckets, Map.new(followers)}
    end
  end

  @doc """
  The static document at `Snapshot.bucket_path/1`: the bucket's version
  and the public seq of every actor in it that has remote followers,
  keyed by `Snapshot.hash/1`. Rendered from the sequence index; in a real
  deployment it is written once per version and served from a cache.
  """
  def bucket_doc(%__MODULE__{} = o, bucket) do
    entries =
      for {key, seq} <- o.seqs,
          Snapshot.public_key?(key),
          Snapshot.bucket(key) == bucket,
          into: %{},
          do: {Snapshot.hash(key), seq}

    %{version: Map.get(o.bucket_versions, bucket, 0), entries: entries}
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
        index <- [:public, :followers],
        key = Visibility.key(actor, index),
        seq = o.seqs[key],
        into: %{} do
      {key, seq}
    end
  end

  defp events_for(o, domain, cursors) do
    for {key, announced} <- announced_for(o, domain),
        announced > Map.get(cursors, key, 0),
        event <- Enum.reverse(Map.fetch!(o.log, key)),
        event.seq > Map.get(cursors, key, 0) do
      event
    end
  end
end
