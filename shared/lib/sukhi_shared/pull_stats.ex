# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.PullStats do
  @moduledoc """
  Pull Federation metrics: counted in memory, written to Postgres in
  batches. This is the one place the `pull_stats` / `pull_peer_stats`
  tables are written, from both nodes.

  `bump/2` is a handful of ETS operations, so it is safe on the hot path
  (one call per notification, per served page, per applied activity). The
  flusher (`start_link/1`, one per node, given that node's `Repo`) folds
  the counters into hourly rows every few seconds — pay once per batch,
  never one row update per event. Counters are the *only* thing lost if a
  node dies mid-interval; nothing else depends on them, so they stay out of
  every transaction (CODE_STYLE §4).

  Each node writes only its own `kind`s, so the two never fight over a
  counter; `kinds/0` lists all of them and what they mean.

  Options for `bump/2`:

    * `:n` — how many (default 1)
    * `:ms` — a duration to add to the kind's sum and max
    * `:host` — also count against this peer host
  """

  use GenServer

  require Logger

  @table :sukhi_pull_stats
  @default_interval 10_000

  @kinds %{
    # origin — delivery node
    "log_appended" => "activities written to the pull log",
    "notify_sent" => "notifications delivered to a peer (ms = request time)",
    "notify_failed" => "notification attempts that failed",
    "push_fallback" => "activities pushed because the peer did not take the notification",
    # origin — gateway
    "stream_served" => "pull requests answered with a page (ms = serving time)",
    "stream_declined" => "pull requests refused: too busy",
    "stream_denied" => "pull requests refused: not signed, not a follower host",
    "activities_served" => "activities returned in pages",
    # puller — gateway
    "notify_received" => "notifications accepted",
    "notify_dropped" => "notifications dropped: rate floor, unknown actor, bad shape",
    "pull_ok" => "pulls that completed (ms = round trip)",
    "pull_failed" => "pulls that failed",
    "pull_declined" => "pulls the origin declined (busy / retry-after)",
    "activities_applied" => "pulled activities applied (ms = publish-to-apply lag)",
    "activities_rejected" => "pulled activities refused at admission",
    "resync" => "pulls that told us our cursor was too old"
  }

  @doc "Every kind and what it counts."
  @spec kinds() :: %{String.t() => String.t()}
  def kinds, do: @kinds

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    # The combined release runs both nodes in one BEAM; the counters are one
    # table there, so the second flusher has nothing to do.
    if Process.whereis(__MODULE__),
      do: :ignore,
      else: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Count one (or `:n`) events. No-op when the flusher is not running."
  @spec bump(String.t(), keyword()) :: :ok
  def bump(kind, opts \\ []) when is_binary(kind) do
    if :ets.whereis(@table) != :undefined do
      n = Keyword.get(opts, :n, 1)
      ms = Keyword.get(opts, :ms)
      host = Keyword.get(opts, :host)

      :ets.update_counter(@table, {:kind, kind}, [{2, n}, {3, ms || 0}], {{:kind, kind}, 0, 0})
      if ms, do: raise_max({:max, kind}, ms)

      if is_binary(host),
        do: :ets.update_counter(@table, {:peer, host, kind}, {2, n}, {{:peer, host, kind}, 0})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp raise_max(key, ms) do
    case :ets.lookup(@table, key) do
      [{_, cur}] when cur >= ms -> :ok
      _ -> :ets.insert(@table, {key, ms})
    end
  end

  @doc """
  Fold what has been counted into the tables, using `repo`. Returns the
  number of rows written. Public so tests (and a shutdown hook) can call it.
  """
  @spec flush(module(), DateTime.t()) :: non_neg_integer()
  def flush(repo, now \\ DateTime.utc_now()) do
    if :ets.whereis(@table) == :undefined, do: 0, else: do_flush(repo, now)
  end

  defp do_flush(repo, now) do
    bucket =
      now |> DateTime.to_naive() |> then(&%{&1 | minute: 0, second: 0, microsecond: {0, 0}})

    at = DateTime.to_naive(now)

    kinds =
      for {{:kind, kind}, _, _} = row <- :ets.tab2list(@table), do: {kind, row}

    peers = for {{:peer, host, kind}, _} = row <- :ets.tab2list(@table), do: {host, kind, row}

    k =
      Enum.count(kinds, fn {kind, {key, n, sum}} ->
        max = take_max(kind)
        :ets.update_counter(@table, key, [{2, -n}, {3, -sum}])

        repo.query!(
          """
          INSERT INTO pull_stats (bucket, kind, n, sum_ms, max_ms) VALUES ($1, $2, $3, $4, $5)
          ON CONFLICT (bucket, kind) DO UPDATE SET
            n = pull_stats.n + EXCLUDED.n,
            sum_ms = pull_stats.sum_ms + EXCLUDED.sum_ms,
            max_ms = GREATEST(pull_stats.max_ms, EXCLUDED.max_ms)
          """,
          [bucket, kind, n, sum, max]
        )

        true
      end)

    p =
      Enum.count(peers, fn {host, kind, {key, n}} ->
        :ets.update_counter(@table, key, {2, -n})

        repo.query!(
          """
          INSERT INTO pull_peer_stats (host, kind, n, last_at) VALUES ($1, $2, $3, $4)
          ON CONFLICT (host, kind) DO UPDATE SET
            n = pull_peer_stats.n + EXCLUDED.n, last_at = EXCLUDED.last_at
          """,
          [host, kind, n, at]
        )

        true
      end)

    k + p
  end

  defp take_max(kind) do
    case :ets.take(@table, {:max, kind}) do
      [{_, v}] -> v
      [] -> 0
    end
  end

  # ── flusher ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    interval = Keyword.get(opts, :interval_ms, @default_interval)
    if interval, do: Process.send_after(self(), :flush, interval)
    {:ok, %{repo: Keyword.fetch!(opts, :repo), interval: interval}}
  end

  @impl true
  def handle_info(:flush, %{repo: repo, interval: interval} = state) do
    try do
      flush(repo)
    rescue
      e -> Logger.warning("pull stats flush failed: #{Exception.message(e)}")
    end

    Process.send_after(self(), :flush, interval)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
