# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PullFederation.Stats do
  @moduledoc """
  Reads the Pull Federation metrics for the admin dashboard. The numbers are
  written elsewhere (`SukhiShared.PullStats`, from both nodes, in batches);
  this module only reads them, in a handful of queries per page view — one
  grouped query per shape, never one per row.

  Three kinds of reading:

    * `totals/1` and `hourly/1` — what happened over a window (counters)
    * `gauges/0` — how things stand right now (rows in tables)
    * `peers/1` — the same counters broken down by peer host
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiShared.{Capability, PeerCapabilities}

  @type totals :: %{String.t() => %{n: integer(), sum_ms: integer(), max_ms: integer()}}

  @doc "Counters per kind over the last `hours` hours."
  @spec totals(pos_integer()) :: totals()
  def totals(hours \\ 24) do
    from(s in "pull_stats",
      where: s.bucket >= ^since(hours),
      group_by: s.kind,
      select: {s.kind, %{n: sum(s.n), sum_ms: sum(s.sum_ms), max_ms: max(s.max_ms)}}
    )
    |> Repo.all()
    |> Map.new(fn {kind, m} ->
      {kind, %{n: to_int(m.n), sum_ms: to_int(m.sum_ms), max_ms: to_int(m.max_ms)}}
    end)
  end

  @doc """
  Hour by hour over the last `hours` hours, oldest first:
  `[%{hour: NaiveDateTime, kinds: %{kind => n}}]`, with empty hours present
  so a gap in activity shows as a gap and not as a shorter table.
  """
  @spec hourly(pos_integer()) :: [map()]
  def hourly(hours \\ 24) do
    rows =
      from(s in "pull_stats",
        where: s.bucket >= ^since(hours),
        select: {type(s.bucket, :naive_datetime), s.kind, s.n}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_, kind, n} -> {kind, n} end)

    first = since(hours)

    for i <- 0..hours do
      hour = NaiveDateTime.add(first, i * 3600)
      %{hour: hour, kinds: Map.new(Map.get(rows, hour, []))}
    end
  end

  # ── derived numbers (pure) ───────────────────────────────────────────────

  @doc """
  The few numbers the cards show, from `totals/1`. Pure.

  `saved_pct` is the share of would-be POSTs that went out as a notification
  instead (`pull_routed / (pull_routed + push_routed)`); `nil` when nothing
  was routed. Averages are `nil` when there is nothing to average.
  """
  @spec derive(totals()) :: map()
  def derive(totals) do
    n = fn kind -> get_in(totals, [kind, :n]) || 0 end
    ms = fn kind -> get_in(totals, [kind, :sum_ms]) || 0 end
    max = fn kind -> get_in(totals, [kind, :max_ms]) || 0 end
    avg = fn kind, count -> if count > 0, do: div(ms.(kind), count) end

    routed = n.("pull_routed") + n.("push_routed")
    applied = n.("activities_applied")

    %{
      notify_sent: n.("notify_sent"),
      notify_failed: n.("notify_failed"),
      notify_avg_ms: avg.("notify_sent", n.("notify_sent")),
      notify_received: n.("notify_received"),
      notify_dropped: n.("notify_dropped"),
      pulls_ok: n.("pull_ok"),
      pulls_failed: n.("pull_failed"),
      pulls_declined: n.("pull_declined"),
      pull_avg_ms: avg.("pull_ok", n.("pull_ok")),
      applied: applied,
      rejected: n.("activities_rejected"),
      resync: n.("resync"),
      # `ms` on activities_applied is publish-to-apply lag; only activities
      # that carried a usable `published` contributed, so this is an average
      # over those, and the max is exact.
      lag_avg_ms: avg.("activities_applied", applied),
      lag_max_ms: max.("activities_applied"),
      served: n.("stream_served"),
      served_avg_ms: avg.("stream_served", n.("stream_served")),
      served_items: n.("activities_served"),
      declined: n.("stream_declined"),
      denied: n.("stream_denied"),
      pull_routed: n.("pull_routed"),
      push_routed: n.("push_routed"),
      saved_pct: if(routed > 0, do: round(n.("pull_routed") * 100 / routed)),
      push_fallback: n.("push_fallback")
    }
  end

  # ── gauges ───────────────────────────────────────────────────────────────

  @doc "Where things stand now."
  @spec gauges() :: map()
  def gauges do
    href = Capability.pull_federation()
    now = NaiveDateTime.utc_now()

    fresh =
      DateTime.utc_now()
      |> DateTime.add(-PeerCapabilities.fresh_days() * 86_400, :second)
      |> DateTime.to_naive()

    peers =
      from(p in "peer_capabilities",
        select: {type(p.hrefs, {:array, :string}), type(p.seen_at, :naive_datetime_usec)}
      )
      |> Repo.all()

    oldest =
      from(l in "pull_log", select: type(min(l.inserted_at), :naive_datetime_usec)) |> Repo.one()

    %{
      advertised: Capability.advertised?(),
      capable_peers:
        Enum.count(peers, fn {hrefs, seen} ->
          href in hrefs and NaiveDateTime.compare(seen, fresh) == :gt
        end),
      known_peers: length(peers),
      pending_hosts: Repo.one(from(p in "pull_pending", select: count(p.host, :distinct))),
      pending_actors: Repo.one(from(p in "pull_pending", select: count())),
      failing_hosts: Repo.one(from(h in "pull_hosts", where: h.failures > 0, select: count())),
      cursors: Repo.one(from(c in "pull_cursors", select: count())),
      log_rows: Repo.one(from(l in "pull_log", select: count())),
      log_oldest_s: if(oldest, do: max(NaiveDateTime.diff(now, oldest), 0), else: 0),
      breaker_open:
        Repo.one(
          from(p in "pull_peers",
            where:
              p.failures >= 5 and p.notified_at > type(^NaiveDateTime.add(now, -1800), :naive_datetime_usec),
            select: count()
          )
        ),
      in_flight: SukhiFedi.PullFederation.Gate.in_flight(),
      max_in_flight: SukhiFedi.PullFederation.Gate.max()
    }
  end

  # ── by peer ──────────────────────────────────────────────────────────────

  @doc """
  The busiest `limit` peers (by total counted events), one map each with the
  kind counters, whether the host currently counts as capable, and the state
  of its notification breaker / pull schedule. Three small queries.
  """
  @spec peers(pos_integer()) :: [map()]
  def peers(limit \\ 30) do
    rows =
      from(p in "pull_peer_stats", select: {p.host, p.kind, p.n, type(p.last_at, :naive_datetime)})
      |> Repo.all()

    by_host = Enum.group_by(rows, &elem(&1, 0))

    hosts =
      by_host
      |> Enum.sort_by(fn {_, es} -> -Enum.sum(Enum.map(es, &elem(&1, 2))) end)
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 0))

    capable = PeerCapabilities.capable_hosts(Repo, hosts)

    notify =
      from(p in "pull_peers",
        where: p.host in ^hosts,
        select: {p.host, %{failures: p.failures, last_error: p.last_error}}
      )
      |> Repo.all()
      |> Map.new()

    pulls =
      from(p in "pull_hosts",
        where: p.host in ^hosts,
        select: {p.host, %{failures: p.failures, last_error: p.last_error}}
      )
      |> Repo.all()
      |> Map.new()

    for host <- hosts do
      entries = by_host[host]

      %{
        host: host,
        counts: Map.new(entries, fn {_, kind, n, _} -> {kind, to_int(n)} end),
        last_at: entries |> Enum.map(&elem(&1, 3)) |> Enum.max(NaiveDateTime),
        capable: MapSet.member?(capable, host),
        notify: Map.get(notify, host),
        pull: Map.get(pulls, host)
      }
    end
  end

  # ── housekeeping ─────────────────────────────────────────────────────────

  @doc "Drop counters older than `days`. Returns rows removed."
  @spec prune(pos_integer()) :: non_neg_integer()
  def prune(days) when is_integer(days) and days > 0 do
    cutoff = since(days * 24)
    {a, _} = Repo.delete_all(from(s in "pull_stats", where: s.bucket < ^cutoff))
    {b, _} = Repo.delete_all(from(s in "pull_peer_stats", where: s.last_at < ^cutoff))
    a + b
  end

  # Start of the hour `hours` ago, as the naive UTC time the tables hold.
  defp since(hours) do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-hours * 3600)
    |> then(&%{&1 | minute: 0, second: 0, microsecond: {0, 0}})
    |> NaiveDateTime.truncate(:second)
  end

  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
end
