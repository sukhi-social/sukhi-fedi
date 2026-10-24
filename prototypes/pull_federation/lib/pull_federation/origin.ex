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

  alias PullFederation.{Calendar, Cursors, Etag, Snapshot, Visibility}

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
            inline_max: 5,
            resyncs: 0,
            known_domains: MapSet.new(),
            last_pull: %{},
            min_pull_gap_ms: 0,
            calendar: nil

  @type event :: %{
          actor: String.t(),
          key: String.t(),
          seq: pos_integer,
          etag: String.t(),
          activity: map
        }

  def new(opts \\ []) do
    o = struct!(__MODULE__, Keyword.drop(opts, [:calendar]))
    cal = Calendar.new(Keyword.merge([slots: o.max_streams], Keyword.get(opts, :calendar, [])))
    %{o | calendar: cal}
  end

  @doc "Record that `domain` follows `actor` (shared-inbox granularity)."
  def follow(%__MODULE__{} = o, domain, actor) do
    %{
      o
      | followers: Map.update(o.followers, actor, MapSet.new([domain]), &MapSet.put(&1, domain)),
        known_domains: MapSet.put(o.known_domains, domain)
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

        event = %{
          actor: actor,
          key: key,
          seq: seq,
          etag: new_etag(index, seq),
          activity: activity
        }

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

  A notification is either the changed ETags inline (`%{key => etag}`,
  when at most `inline_max` public actors changed), or
  `{:buckets, %{bucket => version}, inline_followers}` pointing at the
  snapshot buckets to fetch. Followers-only counters are always inline.
  """
  def due_notifications(%__MODULE__{} = o, now) do
    {due, _held} =
      Enum.split_with(o.dirty, fn {domain, _} ->
        quiet? = now - Map.get(o.last_notified, domain, -o.notify_quiet_ms) >= o.notify_quiet_ms
        # a domain that already holds an appointment will pull; do not nag it
        quiet? and not Calendar.claimed?(o.calendar, domain, now)
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
  and the public ETag of every actor in it that has remote followers,
  keyed by `Snapshot.hash/1`. Rendered from the sequence index; in a real
  deployment it is written once per version and served from a cache.
  """
  def bucket_doc(%__MODULE__{} = o, bucket) do
    entries =
      for {key, _seq} <- o.seqs,
          Snapshot.public_key?(key),
          Snapshot.bucket(key) == bucket,
          into: %{},
          do: {Snapshot.hash(key), etag_of(o, key)}

    %{version: Map.get(o.bucket_versions, bucket, 0), entries: entries}
  end

  @doc """
  Decline when busy, otherwise reserve a slot and return the events the
  remote is missing. The caller must `close_stream/1` when done.
  """
  def open_stream(%__MODULE__{} = o, domain, cursors, now) do
    case request_stream(o, domain, cursors, now) do
      {o, {:ok, events, announced}} -> {:ok, o, events, announced}
      {_o, {:error, err}} -> {:error, err}
    end
  end

  @doc """
  Like `open_stream/4` but returns the updated origin on a decline too,
  because a decline may *book an appointment* (`PullFederation.Calendar`).
  Result: `{o, {:ok, events, announced} | {:error, reason}}`, reason one of
  `:unknown_domain`, `{:busy, ms}` (nothing promised; try again after `ms`),
  `{:retry_at, ms}` (come back in exactly `ms`: the slot is yours).

  Order of checks, cheapest first, none touching the database until a
  stream is granted: known domain, what the domain holds in the calendar,
  the minimum gap, a free slot.
  """
  def request_stream(%__MODULE__{} = o, domain, cursors, now) do
    case known_domain(o, domain) do
      {:error, _} = err -> {o, err}
      :ok -> by_claim(o, domain, cursors, now, Calendar.claim(o.calendar, domain, now))
    end
  end

  # early: told how long is left; nothing else changes
  defp by_claim(o, _domain, _cursors, _now, {:early, ms}), do: {o, {:error, {:retry_at, ms}}}

  # on time (or late within the grace): served if a slot is free
  defp by_claim(o, domain, cursors, now, :due) do
    case slot_free?(o) do
      true ->
        admit(o, domain, cursors, now)

      false ->
        {cal, ms} = Calendar.postpone(o.calendar, domain, now)
        {%{o | calendar: cal}, {:error, {:retry_at, ms}}}
    end
  end

  # no promise, or one that lapsed: a fresh arrival
  defp by_claim(o, domain, cursors, now, fresh) when fresh in [:none, :expired] do
    o = %{o | calendar: Calendar.release(o.calendar, domain)}

    case not_too_soon(o, domain, now) do
      {:error, retry} ->
        {o, {:error, {:retry_at, retry}}}

      :ok ->
        # nobody walks in ahead of domains that hold a promise
        case slot_free?(o) and not Calendar.pending?(o.calendar, now) do
          true -> admit(o, domain, cursors, now)
          false -> book(o, domain, now)
        end
    end
  end

  defp slot_free?(o), do: o.active_streams < o.max_streams

  defp book(o, domain, now) do
    case Calendar.book(o.calendar, domain, now) do
      {cal, {:ok, ms}} -> {%{o | calendar: cal}, {:error, {:retry_at, ms}}}
      {cal, {:shed, ms}} -> {%{o | calendar: cal}, {:error, {:busy, ms}}}
    end
  end

  defp admit(o, domain, cursors, now) do
    {events, resyncs} = events_for(o, domain, cursors)

    o = %{
      o
      | active_streams: o.active_streams + 1,
        resyncs: o.resyncs + resyncs,
        last_pull: Map.put(o.last_pull, domain, now),
        calendar: Calendar.release(o.calendar, domain),
        # everything pending for this domain is in the stream about to be sent
        dirty: Map.delete(o.dirty, domain)
    }

    {o, {:ok, events, announced_for(o, domain)}}
  end

  defp known_domain(o, domain) do
    case MapSet.member?(o.known_domains, domain) do
      true -> :ok
      false -> {:error, :unknown_domain}
    end
  end

  # `min_pull_gap_ms` (0 = off): a domain asking again sooner is told to wait.
  defp not_too_soon(o, domain, now) do
    case Map.fetch(o.last_pull, domain) do
      {:ok, at} when now - at < o.min_pull_gap_ms -> {:error, o.min_pull_gap_ms - (now - at)}
      _ -> :ok
    end
  end

  def close_stream(%__MODULE__{active_streams: n} = o) when n > 0,
    do: %{o | active_streams: n - 1}

  @doc """
  Close a stream and tell the calendar how long it really took, so the
  appointment spacing follows the actual stream time.
  """
  def close_stream(%__MODULE__{} = o, domain, now) do
    o = close_stream(o)

    case Map.fetch(o.last_pull, domain) do
      {:ok, started} -> %{o | calendar: Calendar.observe_stream(o.calendar, now - started)}
      :error -> o
    end
  end

  @doc "Recovery broadcast to every domain that follows anyone here; `jitter.(domain)` is the delay in ms."
  def recovered(%__MODULE__{} = o, jitter) do
    domains = o.followers |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    for d <- Enum.sort(domains), do: {jitter.(d), d, announced_for(o, d)}
  end

  @doc "The token of the newest event under `key`, i.e. the key's current state."
  def etag(%__MODULE__{} = o, key), do: o.log |> Map.fetch!(key) |> hd() |> Map.fetch!(:etag)

  defp etag_of(o, key), do: etag(o, key)

  # The public index equals the public outbox, so its count is no secret.
  defp new_etag(:public, seq), do: Etag.ordered(seq)
  defp new_etag(:followers, _seq), do: Etag.opaque()

  @doc "The current ETag of every key `domain` follows here."
  def announced(o, domain), do: announced_for(o, domain)

  defp announced_for(o, domain) do
    for {actor, domains} <- o.followers,
        MapSet.member?(domains, domain),
        index <- [:public, :followers],
        key = Visibility.key(actor, index),
        Map.has_key?(o.seqs, key),
        into: %{} do
      {key, etag_of(o, key)}
    end
  end

  # Only keys whose token differs from the receiver's are served. A token
  # we do not recognise (too old, forged, from before a restart) means
  # "replay what you still keep"; applying events is idempotent.
  defp events_for(o, domain, cursors) do
    changed = Cursors.changed(cursors, announced_for(o, domain))

    Enum.reduce(Enum.sort(changed), {[], 0}, fn {key, _new}, {acc, resyncs} ->
      log = Enum.reverse(Map.fetch!(o.log, key))

      case after_cursor(log, Map.fetch(cursors, key)) do
        {:ok, events} -> {acc ++ events, resyncs}
        :unknown -> {acc ++ log, resyncs + 1}
      end
    end)
  end

  defp after_cursor(log, :error), do: {:ok, log}

  defp after_cursor(log, {:ok, token}) do
    case Etag.seq(token) do
      {:ok, n} ->
        {:ok, Enum.filter(log, &(&1.seq > n))}

      :error ->
        case Enum.split_while(log, &(&1.etag != token)) do
          {_all, []} -> :unknown
          {_before, [_known | after_it]} -> {:ok, after_it}
        end
    end
  end
end
