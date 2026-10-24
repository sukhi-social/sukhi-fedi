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

  alias PullFederation.{Calendar, Cursors, Etag, Mode, Proof, RequestAuth, Snapshot, Visibility}

  defstruct log: %{},
            seqs: %{},
            followers: %{},
            follows: %{},
            signers: %{},
            delete_jobs: %{},
            delete_max_attempts: 16,
            deletes_given_up: 0,
            nonces: %{},
            bucket_keys: %{},
            log_max: 10_000,
            log_len: %{},
            dirty: %{},
            last_notified: %{},
            active_streams: 0,
            max_streams: 4,
            open: %{},
            stream_timeout_ms: 30_000,
            reaped: 0,
            notify_quiet_ms: 3_000,
            decline_retry_ms: 5_000,
            bucket_versions: %{},
            inline_max: 5,
            resyncs: 0,
            known_domains: MapSet.new(),
            last_pull: %{},
            min_pull_gap_ms: 0,
            calendar: nil,
            mode: nil

  @type event :: %{
          actor: String.t(),
          key: String.t(),
          seq: pos_integer,
          etag: String.t(),
          prev: String.t() | nil,
          activity: map
        }

  def new(opts \\ []) do
    o = struct!(__MODULE__, Keyword.drop(opts, [:calendar, :mode]))
    cal = Calendar.new(Keyword.merge([slots: o.max_streams], Keyword.get(opts, :calendar, [])))
    %{o | calendar: cal, mode: Mode.new(Keyword.get(opts, :mode, []))}
  end

  @doc "Record that `domain` follows `actor` (shared-inbox granularity)."
  def follow(%__MODULE__{} = o, domain, actor) do
    %{
      o
      | followers: Map.update(o.followers, actor, MapSet.new([domain]), &MapSet.put(&1, domain)),
        follows: Map.update(o.follows, domain, MapSet.new([actor]), &MapSet.put(&1, actor)),
        known_domains: MapSet.put(o.known_domains, domain)
    }
  end

  @doc """
  Append an activity. It takes the next seq of its index (public or
  followers-only, see `Visibility`); direct messages return `:push_only`
  and touch no sequence. Every follower domain is told by notification
  (the pull-only path); see `publish_routed/4` for the hybrid.
  """
  def publish(%__MODULE__{} = o, actor, %{visibility: vis} = activity) do
    case append(o, actor, vis, activity) do
      :push_only ->
        {o, :push_only}

      {o, event, domains} ->
        {mark_dirty(o, domains, event.key), {:pull, event.seq}}
    end
  end

  @doc """
  Hybrid publish. The activity is appended exactly as in `publish/3`
  (so the sequence and ETags stay continuous), then each follower domain
  is routed by `Mode`: `:push` domains get the activity itself,
  `:pull` domains are marked for a notification.

  A Delete is always pushed (see the clause below). Returns `{o, {:routed, seq}, pushes}` where `pushes` is
  `[{domain, %{key:, etag:, prev:, activity:}}]`. `prev` is the ETag the
  receiver should hold before applying it: if it does, the receiver
  advances its cursor itself and needs no pull; if not, it knows it
  missed something.
  """
  def publish_routed(%__MODULE__{} = o, actor, %{visibility: vis} = activity, now) do
    case append(o, actor, vis, activity) do
      :push_only ->
        {o, :push_only, []}

      # A Delete is pushed to everyone, whatever the density: it is small, it
      # should land fast, and it does not count towards a domain's rate. It is
      # never turned into "come and get it": a receiver may take its time or
      # never ask, and the content has to go. So each (domain, delete) is a
      # job that is retried with backoff until it is delivered or the attempts
      # run out (`delete_result/5`, `due_deletes/2`).
      {o, event, domains} when activity.type == :delete ->
        pushes = for d <- Enum.sort(domains), do: {d, push_payload(event)}

        jobs =
          Enum.reduce(pushes, o.delete_jobs, fn {d, payload}, acc ->
            Map.put(acc, {d, activity.id}, %{payload: payload, attempt: 1, due: nil})
          end)

        {%{o | delete_jobs: jobs}, {:routed, event.seq}, pushes}

      {o, event, domains} ->
        {o, pushes, pulls} =
          domains
          |> Enum.sort()
          |> Enum.reduce({o, [], []}, fn d, {o, pushes, pulls} ->
            mode = Mode.observe_post(o.mode, d, now)
            {mode, route} = Mode.mode(mode, d, now)
            o = %{o | mode: mode}

            case route do
              :push -> {o, [{d, push_payload(event)} | pushes], pulls}
              :pull -> {o, pushes, [d | pulls]}
            end
          end)

        {mark_dirty(o, pulls, event.key), {:routed, event.seq}, Enum.reverse(pushes)}
    end
  end

  @doc """
  The outcome of pushing a Delete (the first try returned by `publish_routed/4`,
  or a retry from `due_deletes/2`). `:ok` ends the job. `:fail` schedules the
  next try after `n^4 + 15` seconds plus a hash jitter (the Mastodon shape), and
  after `delete_max_attempts` tries gives up and counts it in `deletes_given_up`.
  """
  def delete_result(%__MODULE__{} = o, domain, id, :ok, _now),
    do: %{o | delete_jobs: Map.delete(o.delete_jobs, {domain, id})}

  def delete_result(%__MODULE__{} = o, domain, id, :fail, now) do
    case Map.fetch(o.delete_jobs, {domain, id}) do
      :error ->
        o

      {:ok, %{attempt: n}} when n >= o.delete_max_attempts ->
        %{
          o
          | delete_jobs: Map.delete(o.delete_jobs, {domain, id}),
            deletes_given_up: o.deletes_given_up + 1
        }

      {:ok, %{attempt: n} = job} ->
        base = Integer.pow(n, 4)
        jitter = :erlang.phash2({domain, id, n}, div(base, 2) + 1)
        job = %{job | attempt: n + 1, due: now + (base + 15 + jitter) * 1_000}
        %{o | delete_jobs: Map.put(o.delete_jobs, {domain, id}, job)}
    end
  end

  @doc "Delete pushes whose retry time has come: `{o, [{domain, id, payload}]}`. Report each with `delete_result/5`."
  def due_deletes(%__MODULE__{} = o, now) do
    due = for {{d, id}, %{due: at} = j} <- o.delete_jobs, at != nil and at <= now, do: {d, id, j}

    jobs =
      Enum.reduce(due, o.delete_jobs, fn {d, id, j}, acc ->
        Map.put(acc, {d, id}, %{j | due: nil})
      end)

    {%{o | delete_jobs: jobs},
     due |> Enum.map(fn {d, id, j} -> {d, id, j.payload} end) |> Enum.sort()}
  end

  @doc """
  A push to `domain` failed (429, 5xx, timeout). Do not retry the
  activity: it is in the log, so move the domain to pull and let the
  notification carry it.
  """
  def push_failed(%__MODULE__{} = o, domain, key, now) do
    o = %{o | mode: Mode.observe_failure(o.mode, domain, now)}
    mark_dirty(o, [domain], key)
  end

  # signed once, here, whatever the number of followers or the route (pull, push, hybrid)
  defp sign(o, actor, activity) do
    case Map.fetch(o.signers, actor) do
      {:ok, {key_id, private}} -> Proof.sign(activity, actor, key_id, private)
      :error -> activity
    end
  end

  defp push_payload(event),
    do: %{key: event.key, etag: event.etag, prev: event.prev, activity: event.activity}

  defp append(o, actor, vis, activity) do
    activity = sign(o, actor, activity)

    case Visibility.index(vis) do
      nil ->
        :push_only

      index ->
        key = Visibility.key(actor, index)
        seq = Map.get(o.seqs, key, 0) + 1
        prev = o.log |> Map.get(key, []) |> List.first() |> then(&(&1 && &1.etag))

        event = %{
          actor: actor,
          key: key,
          seq: seq,
          etag: new_etag(index, seq),
          prev: prev,
          activity: activity
        }

        domains = Map.get(o.followers, actor, MapSet.new())
        {log, log_len} = push_log(o, key, event)
        bucket_keys = index_bucket(o.bucket_keys, key, index, seq)
        # actors nobody follows remotely never bump a bucket: nothing to tell anyone
        versions = bump_bucket(o.bucket_versions, actor, index, domains)

        {%{
           o
           | log: log,
             log_len: log_len,
             bucket_keys: bucket_keys,
             seqs: Map.put(o.seqs, key, seq),
             bucket_versions: versions
         }, event, domains}
    end
  end

  # which keys live in which snapshot bucket, so a bucket document does not scan every actor
  defp index_bucket(idx, key, :public, 1),
    do: Map.update(idx, Snapshot.bucket(key), MapSet.new([key]), &MapSet.put(&1, key))

  defp index_bucket(idx, _key, _index, _seq), do: idx

  # Newest first. Kept to `log_max` entries per key; trimmed in batches of
  # `log_max` so a post does not pay for the trim.
  defp push_log(o, key, event) do
    len = Map.get(o.log_len, key, 0) + 1
    entries = [event | Map.get(o.log, key, [])]

    case len > 2 * o.log_max do
      true ->
        {Map.put(o.log, key, Enum.take(entries, o.log_max)), Map.put(o.log_len, key, o.log_max)}

      false ->
        {Map.put(o.log, key, entries), Map.put(o.log_len, key, len)}
    end
  end

  defp mark_dirty(o, domains, key) do
    dirty =
      Enum.reduce(domains, o.dirty, fn d, acc ->
        Map.update(acc, d, MapSet.new([key]), &MapSet.put(&1, key))
      end)

    %{o | dirty: dirty}
  end

  defp bump_bucket(versions, actor, :public, domains) do
    case MapSet.size(domains) do
      0 -> versions
      _ -> Map.update(versions, Snapshot.bucket(actor), 1, &(&1 + 1))
    end
  end

  defp bump_bucket(versions, _actor, :followers, _domains), do: versions

  @doc """
  Notifications whose quiet period has elapsed: `[{domain, notification}]`
  (at most `limit` of them per call, oldest first).

  A notification is either the changed ETags inline (`%{key => etag}`,
  when at most `inline_max` public actors changed), or
  `{:buckets, %{bucket => version}, inline_followers}` pointing at the
  snapshot buckets to fetch. Followers-only counters are always inline.
  """
  def due_notifications(%__MODULE__{} = o, now, limit \\ :infinity) do
    {due, _held} =
      Enum.split_with(o.dirty, fn {domain, _} ->
        quiet? = now - Map.get(o.last_notified, domain, -o.notify_quiet_ms) >= o.notify_quiet_ms
        # a domain that already holds an appointment will pull; do not nag it
        quiet? and not Calendar.claimed?(o.calendar, domain, now)
      end)

    due = take_oldest(o, due, limit)
    msgs = for {domain, dirty} <- due, do: {domain, notification(o, dirty)}

    o = %{
      o
      | dirty: Map.drop(o.dirty, Enum.map(due, &elem(&1, 0))),
        last_notified:
          Enum.reduce(due, o.last_notified, fn {d, _}, acc -> Map.put(acc, d, now) end)
    }

    {o, Enum.sort(msgs)}
  end

  # `limit` caps the work of one call so a busy origin keeps answering its
  # authors; whoever was told longest ago goes first, the rest stay dirty for the next call.
  defp take_oldest(_o, due, :infinity), do: due

  defp take_oldest(o, due, limit) do
    due
    |> Enum.sort_by(fn {d, _} -> {Map.get(o.last_notified, d, -1), d} end)
    |> Enum.take(limit)
  end

  defp notification(o, dirty) do
    # only the keys that changed, not everything the domain follows
    changed = Map.new(dirty, &{&1, etag_of(o, &1)})
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
      for key <- Map.get(o.bucket_keys, bucket, []),
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
  The boundary for pull requests from the network. The requester is
  authenticated here, once (`RequestAuth.verify/5`), and a nonce is
  accepted only once within its window, so a captured request cannot be
  replayed. Behind it `request_stream/4` trusts the domain.

  Errors: `{:error, :unauthenticated | :expired | :replayed}`; none of
  them touches the calendar, a slot or the database.
  """
  def authenticated_stream(%__MODULE__{} = o, req, keys, target, cursors, now) do
    o = prune_nonces(o, now)

    with {:ok, domain, nonce, expires} <- RequestAuth.verify(req, keys, target, cursors, now),
         :ok <- fresh_nonce(o, nonce) do
      request_stream(%{o | nonces: Map.put(o.nonces, nonce, expires)}, domain, cursors, now)
    else
      {:error, _} = err -> {o, err}
    end
  end

  defp fresh_nonce(o, nonce),
    do: if(Map.has_key?(o.nonces, nonce), do: {:error, :replayed}, else: :ok)

  defp prune_nonces(o, now) do
    # bounded by the requests of one window
    %{o | nonces: Map.reject(o.nonces, fn {_n, exp} -> exp < now end)}
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
    o = reap(o, now)

    with :ok <- known_domain(o, domain),
         :ok <- not_streaming(o, domain, now) do
      by_claim(o, domain, cursors, now, Calendar.claim(o.calendar, domain, now))
    else
      {:error, _} = err -> {o, err}
    end
  end

  @doc """
  A stream the receiver never closes (crashed, stalled, busy forever) must
  not hold a slot for good: after `stream_timeout_ms` the slot is taken
  back. Called on every request, and by whoever counts free slots before
  asking (a caller with a shared worker pool).
  """
  def reap(%__MODULE__{} = o, now) do
    {dead, live} = Enum.split_with(o.open, fn {_, at} -> now - at > o.stream_timeout_ms end)

    %{
      o
      | open: Map.new(live),
        active_streams: max(0, o.active_streams - length(dead)),
        reaped: o.reaped + length(dead)
    }
  end

  # one stream per domain at a time; asking again while one is open is a
  # receiver that lost track of it, and will be served once it closes or times out
  defp not_streaming(o, domain, now) do
    case Map.fetch(o.open, domain) do
      {:ok, at} -> {:error, {:busy, max(o.stream_timeout_ms - (now - at), 1)}}
      :error -> :ok
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
        open: Map.put(o.open, domain, now),
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

  def close_stream(%__MODULE__{active_streams: n} = o) when n > 0 do
    # without a domain, the oldest open stream is the one that ended
    open =
      case Enum.min_by(o.open, &elem(&1, 1), fn -> nil end) do
        nil -> o.open
        {domain, _} -> Map.delete(o.open, domain)
      end

    %{o | active_streams: n - 1, open: open}
  end

  @doc """
  Close a stream and tell the calendar how long it really took, so the
  appointment spacing follows the actual stream time.
  """
  def close_stream(%__MODULE__{} = o, domain, now) do
    # a stream that was already reaped gave its slot back; not twice
    o =
      case Map.pop(o.open, domain) do
        {nil, _} -> o
        {_, open} -> %{close_stream(o) | open: open}
      end

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
    for actor <- Map.get(o.follows, domain, []),
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

    {chunks, resyncs} =
      Enum.reduce(Enum.sort(changed), {[], 0}, fn {key, _new}, {acc, resyncs} ->
        log = Map.fetch!(o.log, key)

        case after_cursor(log, Map.fetch(cursors, key)) do
          {:ok, events} -> {[events | acc], resyncs}
          :unknown -> {[Enum.reverse(log) | acc], resyncs + 1}
        end
      end)

    {chunks |> Enum.reverse() |> Enum.concat(), resyncs}
  end

  # `log` is newest first; the answer is oldest first and costs what it returns.
  defp after_cursor(log, :error), do: {:ok, Enum.reverse(log)}

  defp after_cursor(log, {:ok, token}) do
    case Etag.seq(token) do
      {:ok, n} ->
        {newer, _} = Enum.split_while(log, &(&1.seq > n))

        # the entry just before the answer must be `n` or still be retained;
        # otherwise trimmed events lie in between and the receiver must resync
        case newer do
          [] -> {:ok, []}
          _ -> if List.last(newer).seq > n + 1, do: :unknown, else: {:ok, Enum.reverse(newer)}
        end

      :error ->
        case Enum.split_while(log, &(&1.etag != token)) do
          {_all, []} -> :unknown
          {before, [_known | _]} -> {:ok, Enum.reverse(before)}
        end
    end
  end
end
