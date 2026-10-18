# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.ActorFetcher do
  @moduledoc """
  Fetches remote ActivityPub Actor JSON documents and caches them in
  ETS (`:actor_remote` table) for an hour.

  The cache is node-local, so a hit never leaves the gateway. A miss
  goes through the Bun `fedify.fetch.v1` endpoint, which HTTP-signs the
  GET — Mastodon Secure Mode and Misskey auth-fetch-required peers
  reject unsigned actor dereferences.
  """

  require Logger
  alias SukhiFedi.Cache.Ets
  alias SukhiFedi.Federation.FedifyClient

  @ttl_seconds 3_600

  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(actor_uri) when is_binary(actor_uri) do
    case Ets.get(:actor_remote, actor_uri) do
      {:ok, actor} -> {:ok, actor}
      :miss -> do_fetch(actor_uri)
    end
  end

  @doc """
  Fetch from the origin, ignoring (and replacing) the cached copy. For
  when we have been told the actor changed (`Update`): the hour-old cache
  entry is exactly the stale document we must not read back.
  """
  @spec refresh(String.t()) :: {:ok, map()} | {:error, term()}
  def refresh(actor_uri) when is_binary(actor_uri) do
    Ets.delete(:actor_remote, actor_uri)
    do_fetch(actor_uri)
  end

  defp do_fetch(actor_uri) do
    case FedifyClient.fetch(actor_uri, SukhiFedi.Accounts.signing_identity()) do
      {:ok, %{"document" => actor}} when is_map(actor) ->
        Ets.put(:actor_remote, actor_uri, actor, @ttl_seconds)
        {:ok, actor}

      {:ok, other} ->
        {:error, {:unexpected_fetch_result, other}}

      {:error, reason} ->
        Logger.warning("ActorFetcher: #{actor_uri} fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
