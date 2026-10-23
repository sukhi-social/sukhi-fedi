# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Puller do
  @moduledoc """
  Instance B. Pure state machine; every function takes `now` (ms).

  Flow: `notify/4` (untrusted POST) -> plan -> `next_pull/3` when idle ->
  caller talks to the origin -> `finish_pull/5` applies events.

  Backpressure lives here: a bounded pool (`max_pending`), a per-origin
  notification floor (`min_notify_gap_ms`), and postponement while busy.
  Pushed activities use the same `apply_activity/3` as pulled ones, so
  "both ways" delivery is idempotent through one code path.
  """

  alias PullFederation.{Cursors, Snapshot, Visibility}

  defstruct following: %{},
            cursors: %{},
            pending: %{},
            not_before: %{},
            last_accepted: %{},
            store: %{},
            tombstones: MapSet.new(),
            rejected: 0,
            max_pending: 64,
            min_notify_gap_ms: 1_000,
            retry_base_ms: 5_000,
            retry_max_ms: 300_000,
            failures: %{},
            bucket_seen: %{},
            inflight: %{},
            wanted: %{},
            verify: nil

  @doc "`verify` is `(activity -> :ok | :error)`, the single signature check."
  def new(opts \\ []) do
    opts = Keyword.put_new(opts, :verify, fn _ -> :ok end)
    struct!(__MODULE__, opts)
  end

  @doc "B follows `actor` on `origin` (a domain)."
  def follow(%__MODULE__{} = b, origin, actor) do
    %{b | following: Map.update(b.following, origin, MapSet.new([actor]), &MapSet.put(&1, actor))}
  end

  @doc """
  Step 3. Returns `{b, :planned | :up_to_date | :fetch | :rate_limited | :invalid | :pool_full}`;
  `:fetch` means snapshot buckets are wanted (`wanted_buckets/2`, `ingest_bucket/5`).
  Announced actors we do not follow are dropped, so a notification can
  never widen what we are willing to pull.
  """
  def notify(%__MODULE__{} = b, origin, notification, now) do
    with :ok <- gap_ok(b, origin, now),
         {:ok, inline, versions} <- parse_notification(notification) do
      b = %{b | last_accepted: Map.put(b.last_accepted, origin, now)}
      {b, status} = plan_inline(b, origin, inline)
      b = want_buckets(b, origin, versions)

      case Map.get(b.wanted, origin, %{}) == %{} do
        true -> {b, status}
        false -> {b, :fetch}
      end
    else
      :rate_limited -> {b, :rate_limited}
      :error -> {b, :invalid}
    end
  end

  # Untrusted input, parsed once here: either inline ETags or bucket versions.
  defp parse_notification({:buckets, versions, inline}) when is_map(versions) do
    valid? = Enum.all?(versions, fn {k, v} -> is_binary(k) and is_integer(v) and v >= 0 end)

    with true <- valid? and map_size(versions) <= 256,
         {:ok, parsed} <- Cursors.parse(inline) do
      {:ok, parsed, versions}
    else
      _ -> :error
    end
  end

  defp parse_notification(inline) do
    with {:ok, parsed} <- Cursors.parse(inline), do: {:ok, parsed, %{}}
  end

  defp plan_inline(b, origin, parsed) do
    followed = Map.get(b.following, origin, MapSet.new())

    relevant =
      Map.filter(parsed, fn {key, _} -> MapSet.member?(followed, Visibility.actor_of(key)) end)

    plan(b, origin, Cursors.changed(Map.get(b.cursors, origin, %{}), relevant))
  end

  defp want_buckets(b, origin, versions) do
    seen = Map.get(b.bucket_seen, origin, %{})
    mine = my_buckets(b, origin)

    fetch =
      for {bucket, v} <- versions,
          MapSet.member?(mine, bucket),
          v > Map.get(seen, bucket, 0),
          into: %{},
          do: {bucket, v}

    %{b | wanted: Map.update(b.wanted, origin, fetch, &Map.merge(&1, fetch))}
  end

  defp my_buckets(b, origin) do
    b.following
    |> Map.get(origin, MapSet.new())
    |> MapSet.new(&Snapshot.bucket/1)
  end

  @doc "Snapshot buckets the last notification asked this side to fetch."
  def wanted_buckets(%__MODULE__{} = b, origin),
    do: b.wanted |> Map.get(origin, %{}) |> Map.keys() |> Enum.sort()

  @doc """
  Use a fetched bucket document: remember its version, diff the actors we
  follow in it against our cursors, and plan a pull if any is ahead.
  Entries for actors we do not follow are ignored.
  """
  def ingest_bucket(%__MODULE__{} = b, origin, bucket, %{version: v, entries: entries}, _now) do
    followed = Map.get(b.following, origin, MapSet.new())

    announced =
      for actor <- followed,
          Snapshot.bucket(actor) == bucket,
          etag = entries[Snapshot.hash(actor)],
          into: %{},
          do: {actor, etag}

    b = %{
      b
      | bucket_seen: Map.update(b.bucket_seen, origin, %{bucket => v}, &Map.put(&1, bucket, v)),
        wanted: Map.update(b.wanted, origin, %{}, &Map.delete(&1, bucket))
    }

    behind = Cursors.changed(Map.get(b.cursors, origin, %{}), announced)
    plan(b, origin, behind)
  end

  defp gap_ok(b, origin, now) do
    case Map.fetch(b.last_accepted, origin) do
      {:ok, at} when now - at < b.min_notify_gap_ms -> :rate_limited
      _ -> :ok
    end
  end

  defp plan(b, _origin, behind) when map_size(behind) == 0, do: {b, :up_to_date}

  defp plan(b, origin, behind) do
    case {Map.has_key?(b.pending, origin), map_size(b.pending) >= b.max_pending} do
      {false, true} ->
        {b, :pool_full}

      _ ->
        {%{b | pending: Map.update(b.pending, origin, behind, &Cursors.merge(&1, behind))},
         :planned}
    end
  end

  @doc """
  Steps 4-5. `busy?` postpones everything. Otherwise pick the origin
  whose retry time has passed, oldest name first for determinism.
  """
  def next_pull(%__MODULE__{} = b, now, busy?) do
    ready =
      for {origin, _} <- b.pending, Map.get(b.not_before, origin, 0) <= now, do: origin

    case {busy?, Enum.sort(ready)} do
      {true, _} -> :postponed
      {false, []} -> :idle
      {false, [origin | _]} -> {:pull, origin, Map.get(b.cursors, origin, %{})}
    end
  end

  @doc """
  Call when a pull starts. Remembers what was pending at that moment:
  tokens cannot be ordered, so after the stream ends only entries that
  *changed since this point* may still be news; the rest are covered by
  the state the stream returned.
  """
  def begin_pull(%__MODULE__{} = b, origin) do
    %{b | inflight: Map.put(b.inflight, origin, Map.get(b.pending, origin, %{}))}
  end

  @doc """
  Steps 6/8. `result` is `{:ok, events, announced}` or `{:error, {:busy, retry_ms}}`.
  `jitter.(max_ms)` returns 0..max_ms; injected so tests are deterministic.
  """
  def finish_pull(%__MODULE__{} = b, origin, {:ok, events, announced}, now, _jitter) do
    b = Enum.reduce(events, b, &apply_event(&2, origin, &1, now))
    cursors = Map.update(b.cursors, origin, announced, &Cursors.merge(&1, announced))
    news = changed_since_begin(b, origin)
    still_behind = Cursors.changed(cursors[origin], news)

    pending =
      case map_size(still_behind) do
        0 -> Map.delete(b.pending, origin)
        _ -> Map.put(b.pending, origin, still_behind)
      end

    %{
      b
      | cursors: cursors,
        pending: pending,
        inflight: Map.delete(b.inflight, origin),
        failures: Map.delete(b.failures, origin)
    }
  end

  def finish_pull(%__MODULE__{} = b, origin, {:error, {:busy, retry_ms}}, now, jitter) do
    b = %{b | inflight: Map.delete(b.inflight, origin)}
    n = Map.get(b.failures, origin, 0) + 1
    backoff = min(b.retry_base_ms * Integer.pow(2, n - 1), b.retry_max_ms)
    wait = max(retry_ms, backoff) + jitter.(div(backoff, 2))

    %{
      b
      | failures: Map.put(b.failures, origin, n),
        not_before: Map.put(b.not_before, origin, now + wait)
    }
  end

  defp changed_since_begin(b, origin) do
    pending = Map.get(b.pending, origin, %{})

    case Map.fetch(b.inflight, origin) do
      {:ok, at_start} -> Map.reject(pending, fn {k, t} -> Map.get(at_start, k) == t end)
      :error -> pending
    end
  end

  defp apply_event(b, origin, %{key: key, etag: etag, activity: act}, now) do
    cursor = Map.get(b.cursors, origin, %{})
    b = apply_activity(b, act, now)
    # cursor moves per event so a crash mid-stream resumes, never re-reads
    %{b | cursors: Map.put(b.cursors, origin, Cursors.merge(cursor, %{key => etag}))}
  end

  @doc """
  The one ingestion point (pull and push). Verify, then classify:
  Delete wins over a later-arriving Create; duplicates are no-ops.
  """
  def apply_activity(%__MODULE__{} = b, activity, _now) do
    case b.verify.(activity) do
      :error -> %{b | rejected: b.rejected + 1}
      :ok -> classify(b, activity)
    end
  end

  defp classify(b, %{type: :delete, object: id}) do
    %{b | store: Map.delete(b.store, id), tombstones: MapSet.put(b.tombstones, id)}
  end

  defp classify(b, %{type: :create, id: id} = act) do
    case MapSet.member?(b.tombstones, id) or Map.has_key?(b.store, id) do
      true -> b
      false -> %{b | store: Map.put(b.store, id, act)}
    end
  end
end
