# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.NodeinfoMonitor.NodeinfoFetcher do
  @moduledoc """
  Two-step NodeInfo discovery fetch for a given domain:

    1. `GET https://<domain>/.well-known/nodeinfo` → returns JSON with
       a `links` array; pick the highest schema version we understand.
    2. `GET <linked_href>` → returns the actual NodeInfo 2.x document.

  Result is cached in ETS (`:nodeinfo` table) with a short TTL so that
  accidental bursts in the same poll window are deduped. Real polling
  cadence is controlled by the Oban cron, not by this cache.
  """

  require Logger

  alias SukhiFedi.Cache.Ets

  @ttl_seconds 60
  @timeout_ms 10_000

  @supported_schemas ~w(
    http://nodeinfo.diaspora.software/ns/schema/2.1
    http://nodeinfo.diaspora.software/ns/schema/2.0
  )

  @type snapshot :: %{
          version: String.t() | nil,
          software_name: String.t() | nil,
          raw: map()
        }

  @spec fetch(String.t()) :: {:ok, snapshot()} | {:error, term()}
  def fetch(domain) when is_binary(domain) do
    case Ets.get(:nodeinfo, domain) do
      {:ok, cached} -> {:ok, cached}
      :miss -> do_fetch(domain)
    end
  end

  defp do_fetch(domain) do
    with {:ok, href} <- discover(domain),
         {:ok, doc} <- get_json(href) do
      snapshot = to_snapshot(doc)
      Ets.put(:nodeinfo, domain, snapshot, @ttl_seconds)
      {:ok, snapshot}
    end
  end

  defp discover(domain) do
    url = "https://#{domain}/.well-known/nodeinfo"

    with {:ok, doc} <- get_json(url),
         {:ok, href} <- pick_link(doc) do
      {:ok, href}
    end
  end

  defp pick_link(%{"links" => links}) when is_list(links) do
    by_schema =
      links
      |> Enum.filter(&is_map/1)
      |> Enum.filter(fn l -> l["rel"] in @supported_schemas end)
      |> Enum.sort_by(fn l -> -index_of(@supported_schemas, l["rel"]) end)

    case by_schema do
      [%{"href" => href} | _] when is_binary(href) -> {:ok, href}
      _ -> {:error, :no_supported_nodeinfo_schema}
    end
  end

  defp pick_link(_), do: {:error, :nodeinfo_discovery_malformed}

  defp index_of(list, item) do
    Enum.find_index(list, &(&1 == item)) || length(list)
  end

  defp to_snapshot(%{"software" => sw} = doc) when is_map(sw) do
    %{
      version: Map.get(sw, "version"),
      software_name: Map.get(sw, "name"),
      raw: doc
    }
  end

  defp to_snapshot(doc) do
    %{version: nil, software_name: nil, raw: doc}
  end

  defp get_json(url) do
    headers = [
      {"accept", "application/json"},
      {"user-agent", "sukhi-fedi-monitor/0.1.0"}
    ]

    case SukhiFedi.Fedi.HttpFetch.capped_get(url,
           headers: headers,
           receive_timeout: @timeout_ms
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case SukhiFedi.Fedi.HttpFetch.decode_json(body) do
          {:ok, json} -> {:ok, json}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      {:ok, %{status: status}} ->
        Logger.debug("NodeinfoFetcher: #{url} returned HTTP #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.debug("NodeinfoFetcher: #{url} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
