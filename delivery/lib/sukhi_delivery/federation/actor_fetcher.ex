# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Federation.ActorFetcher do
  @moduledoc """
  Delivery-side mirror of `SukhiFedi.Federation.ActorFetcher`.

  Fetches remote ActivityPub Actor JSON via HTTPS (re-using the
  delivery node's existing Finch pool) and caches it in ETS.

  Used by `Outbox.Consumer` to resolve a recipient's `inbox` /
  `endpoints.sharedInbox` from the actor JSON when convention
  (`<actor_uri>/inbox`) is wrong — notably Misskey's per-user paths.
  """

  require Logger
  alias SukhiDelivery.Cache.Ets

  @ttl_seconds 3_600
  @timeout_ms 10_000

  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(actor_uri) when is_binary(actor_uri) do
    case Ets.get(:delivery_actor_remote, actor_uri) do
      {:ok, actor} -> {:ok, actor}
      :miss -> do_fetch(actor_uri)
    end
  end

  @doc """
  Resolve the best inbox URL for an actor. Prefers `endpoints.sharedInbox`
  (cuts fan-out cost dramatically on Mastodon/Misskey peers), falls back
  to `inbox`, then to the `<actor_uri>/inbox` convention as a last resort.
  """
  @spec inbox_for(String.t()) :: String.t() | nil
  def inbox_for(actor_uri) when is_binary(actor_uri) do
    case fetch(actor_uri) do
      {:ok, actor} ->
        shared_inbox(actor) || inbox(actor) || "#{actor_uri}/inbox"

      {:error, _} ->
        "#{actor_uri}/inbox"
    end
  end

  defp shared_inbox(%{"endpoints" => %{"sharedInbox" => uri}}) when is_binary(uri), do: uri
  defp shared_inbox(_), do: nil

  defp inbox(%{"inbox" => uri}) when is_binary(uri), do: uri
  defp inbox(_), do: nil

  defp do_fetch(actor_uri) do
    if not SukhiShared.UrlGuard.safe?(actor_uri) do
      {:error, :blocked_host}
    else
      do_fetch_safe(actor_uri)
    end
  end

  defp do_fetch_safe(actor_uri) do
    headers = [
      {"accept", "application/activity+json, application/ld+json"},
      {"user-agent", "sukhi-fedi-delivery/0.1.0"}
    ]

    case Req.get(actor_uri,
           headers: headers,
           finch: SukhiDelivery.Finch,
           receive_timeout: @timeout_ms
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        Ets.put(:delivery_actor_remote, actor_uri, body, @ttl_seconds)
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case JSON.decode(body) do
          {:ok, actor} ->
            Ets.put(:delivery_actor_remote, actor_uri, actor, @ttl_seconds)
            {:ok, actor}

          {:error, reason} ->
            {:error, {:invalid_json, reason}}
        end

      {:ok, %{status: status}} ->
        Logger.warning("delivery ActorFetcher: #{actor_uri} HTTP #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("delivery ActorFetcher: #{actor_uri} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
