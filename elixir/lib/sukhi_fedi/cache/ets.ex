# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Cache.Ets do
  @moduledoc """
  ETS wrapper with TTL sweep. Manages all in-memory cache tables.
  TTL sweep runs every 60 seconds via GenServer.
  """

  use GenServer

  @tables [
    :key_cache,
    :webfinger,
    :follower_list,
    :session,
    :actor_remote,
    :nodeinfo,
    # signing-key / actor documents fetched by SukhiFedi.Fedi.Fetcher
    :fedi_documents,
    # 裏で encode した AVIF (Web.MediaTranscode.Worker が置く)
    :media_variants
  ]
  @sweep_interval_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Get a cached value. Returns {:ok, value} or :miss."
  @spec get(atom(), term()) :: {:ok, term()} | :miss
  def get(table, key) do
    now = System.system_time(:second)

    case :ets.lookup(table, key) do
      [{^key, value, expiry}] when expiry > now -> {:ok, value}
      _ -> :miss
    end
  end

  @doc "Put a value into the cache with a TTL in seconds."
  @spec put(atom(), term(), term(), non_neg_integer()) :: true
  def put(table, key, value, ttl_seconds) do
    expiry = System.system_time(:second) + ttl_seconds
    :ets.insert(table, {key, value, expiry})
  end

  @doc "Delete a value from the cache."
  @spec delete(atom(), term()) :: true
  def delete(table, key) do
    :ets.delete(table, key)
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    Enum.each(@tables, fn table ->
      :ets.new(table, [:named_table, :public, read_concurrency: true])
    end)

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  defp sweep_expired do
    now = System.system_time(:second)

    Enum.each(@tables, fn table ->
      :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    end)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
