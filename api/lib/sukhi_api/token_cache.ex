# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.TokenCache do
  @moduledoc """
  ETS-backed positive cache for bearer-token verification.

  Wraps `SukhiFedi.OAuth.verify_bearer/1` so a hot path (every
  authenticated REST request) doesn't have to RPC into the gateway
  for the same token over and over. Keyed by the SHA-256 of the raw
  token — we never write the token itself to ETS or to logs.

  TTL is short on purpose (60 s by default). The gateway is the only
  source of truth for revocation; the cache is just a sliding window
  that buys us roughly one RPC per token per minute under load.

  Negative results (`{:error, _}`) are never cached: if the gateway
  returned :revoked once we still want the next call to ask again,
  so a re-issued token doesn't sit in a cached-bad state.

  `session/1` is the same window for the `session_token` cookie
  (`SukhiFedi.Accounts.get_account_by_session_token/1`), kept in the
  same table under a tagged key so the two kinds of token can never
  answer for each other.
  """

  use GenServer

  alias SukhiApi.GatewayRpc

  @table :sukhi_api_token_cache
  @default_ttl_ms 60_000
  @sweep_interval_ms 60_000
  @gateway_oauth SukhiFedi.OAuth

  # ── public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Resolve a bearer token to its `%{account, app, scopes}` context.

  Answers in `GatewayRpc.run/4`'s shape, hit or miss:

      {:ok, ctx}              — verified
      {:error, reason}        — revoked, expired, unknown, …
      {:unavailable, why}     — gateway RPC unreachable (no cache fallback)

  Honours TTL: cached entries older than `ttl_ms` are treated as a miss.
  """
  @spec verify(String.t(), pos_integer()) :: GatewayRpc.result()
  def verify(token, ttl_ms \\ @default_ttl_ms) when is_binary(token) do
    if cache_enabled?() do
      key = key_for(token)
      now = System.monotonic_time(:millisecond)
      cutoff = now - ttl_ms

      case lookup(key, cutoff) do
        {:ok, ctx} -> {:ok, ctx}
        :miss -> do_verify(key, token, now)
      end
    else
      # Tests inject a fake gateway RPC by setting :gateway_rpc_impl;
      # caching would let one test's response leak into the next. The
      # real prod path with a nil impl uses the cache.
      GatewayRpc.run(@gateway_oauth, :verify_bearer, [token])
    end
  end

  @doc """
  Resolve a `session_token` cookie value to its account.

      {:ok, account}          — a live session
      {:error, :no_session}   — expired, revoked, or never was
      {:unavailable, why}     — gateway unreachable

  Only live sessions are cached (a revoked one must be seen as such
  on the next request, same as bearers).
  """
  @spec session(String.t(), pos_integer()) :: GatewayRpc.result()
  def session(token, ttl_ms \\ @default_ttl_ms) when is_binary(token) do
    key = {:session, key_for(token)}
    now = System.monotonic_time(:millisecond)

    case cache_enabled?() and lookup(key, now - ttl_ms) do
      {:ok, account} ->
        {:ok, account}

      _ ->
        case GatewayRpc.run(SukhiFedi.Accounts, :get_account_by_session_token, [token]) do
          {:ok, nil} ->
            {:error, :no_session}

          {:ok, account} ->
            if cache_enabled?(), do: safe_insert(key, now, account)
            {:ok, account}

          other ->
            other
        end
    end
  end

  defp cache_enabled? do
    Application.get_env(:sukhi_api, :gateway_rpc_impl) == nil
  end

  # ── GenServer (table owner + TTL sweep) ─────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @default_ttl_ms * 2
    ms = [{{:_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}]
    :ets.select_delete(@table, ms)
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp lookup(key, cutoff) do
    case :ets.lookup(@table, key) do
      [{^key, inserted_at, ctx}] when inserted_at >= cutoff -> {:ok, ctx}
      _ -> :miss
    end
  rescue
    # Table not yet created (e.g. unit tests bypassing supervisor).
    ArgumentError -> :miss
  end

  defp do_verify(key, token, now) do
    case GatewayRpc.run(@gateway_oauth, :verify_bearer, [token]) do
      {:ok, ctx} = ok ->
        safe_insert(key, now, ctx)
        ok

      # Negative results and outages are not cached — revocation
      # visibility matters more than the saved RPC.
      other ->
        other
    end
  end

  defp safe_insert(key, now, ctx) do
    :ets.insert(@table, {key, now, ctx})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp key_for(token), do: :crypto.hash(:sha256, token)
end
