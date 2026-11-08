# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.HotCache do
  @moduledoc """
  A second or two of memory for answers that are the same for everyone:
  the public timeline's first page, the silenced-author set, the bubble
  allow-list, the admin dashboard, the public map. It is the one place this
  server keeps an answer for a little while; nothing else rolls its own.

  Under load the same question arrives many times a second. Asking the
  database once per TTL instead of once per request is the cheapest DB
  relief there is, and what it costs is bounded and visible here: an answer
  can be at most `ttl` seconds old. Cursor pages (`max_id` / `since_id`)
  and anything per-viewer are not cached by the callers; only the hot head.

  TTLs are in whole seconds (`Cache.Ets` resolution), so a `2` serves an
  answer for between 1 and 2 seconds. `config :sukhi_fedi, :hot_cache,
  false` turns every TTL into 0 — the test config does this, so a sandbox
  rollback never leaves a stale answer for the next test.
  """

  alias SukhiFedi.Cache.Ets

  @table :hot_cache
  @defaults %{
    public_timeline: 2,
    tag_timeline: 2,
    bubble_timeline: 2,
    moderation_sets: 5,
    map: 5,
    stats_dashboard: 30,
    account_counts: 60,
    # who the server names as its contact; every client asks at startup
    site_contact: 60,
    # a finished translation, so a post many people ask for is translated once
    translate: 600
  }

  @doc "TTL in seconds for `name`; 0 when the cache is switched off."
  @spec ttl(atom()) :: non_neg_integer()
  def ttl(name) do
    case Application.get_env(:sukhi_fedi, :hot_cache, true) do
      false -> 0
      overrides when is_list(overrides) -> Keyword.get(overrides, name, @defaults[name] || 0)
      _ -> Map.get(@defaults, name, 0)
    end
  end

  @doc "Return the cached value for `key`, or run `fun`, keep its result `ttl` seconds, and return it."
  @spec fetch(term(), non_neg_integer(), (-> term())) :: term()
  def fetch(_key, ttl, fun) when ttl <= 0, do: fun.()

  def fetch(key, ttl, fun) do
    case Ets.get(@table, key) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        Ets.put(@table, key, value, ttl)
        value
    end
  end

  @doc """
  Like `fetch/3`, but only an `{:ok, _}` answer is kept: an error (the engine was
  busy, the key was refused) is returned and forgotten, so the next ask tries again
  instead of repeating the failure for `ttl` seconds.
  """
  @spec fetch_ok(term(), non_neg_integer(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch_ok(_key, ttl, fun) when ttl <= 0, do: fun.()

  def fetch_ok(key, ttl, fun) do
    case Ets.get(@table, key) do
      {:ok, {:ok, _} = hit} ->
        hit

      _ ->
        case fun.() do
          {:ok, _} = ok ->
            Ets.put(@table, key, ok, ttl)
            ok

          other ->
            other
        end
    end
  end

  @doc "Let go of `key` now, so the next `fetch/3` asks again."
  @spec forget(term()) :: true
  def forget(key), do: Ets.delete(@table, key)
end
