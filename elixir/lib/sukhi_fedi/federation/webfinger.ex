# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.WebFinger do
  @moduledoc """
  Outbound WebFinger client: maps `acct:user@host` to the actor's
  ActivityPub `self` URL via `https://{host}/.well-known/webfinger`.

  Used by `Accounts.lookup_by_acct/2` when the caller asks to resolve
  remote handles. The discovered URL is then fed into
  `Federation.ActorFetcher.fetch/1` + `Federation.RemoteAccounts.upsert/1`.
  """

  require Logger
  alias SukhiFedi.Cache.Ets

  @ttl_seconds 3_600
  @timeout_ms 10_000

  @doc """
  What to ask, and of whom: `{:ok, {host, resource}}` for a handle
  (`name@host`, `@name@host` → `acct:name@host`) or an http(s) URL (the
  URL itself, asked of its own host — an actor URI or a profile page,
  whichever that server answers). `:error` for anything else.
  """
  @spec parse_resource(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def parse_resource(input) when is_binary(input) do
    input = String.trim(input)

    case Regex.run(~r/\A@?([^@\s\/:]+)@([^@\s\/]+)\z/, input) do
      [_, name, host] ->
        {:ok, {host, "acct:#{name}@#{host}"}}

      nil ->
        case URI.parse(input) do
          %URI{scheme: s, host: h} = uri when s in ["http", "https"] and is_binary(h) and h != "" ->
            {:ok, {authority(uri), input}}

          _ ->
            :error
        end
    end
  end

  defp authority(%URI{host: h, port: port, scheme: s}) do
    if port in [nil, URI.default_port(s)], do: h, else: "#{h}:#{port}"
  end

  @doc """
  Ask the host about `input` (see `parse_resource/1`) and return the
  actor's `self` URL (the canonical AP id). Success means the server
  itself vouched for it. Result is ETS-cached for an hour, keyed on the
  resource.
  """
  @spec resolve_self(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_self(input) when is_binary(input) do
    with {:ok, {host, resource}} <- parse(input) do
      case Ets.get(:webfinger, {:self, resource}) do
        {:ok, url} ->
          {:ok, url}

        :miss ->
          with {:ok, jrd} <- fetch_jrd(host, resource),
               {:ok, self_url} <- pick_self(jrd) do
            Ets.put(:webfinger, {:self, resource}, self_url, @ttl_seconds)
            {:ok, self_url}
          end
      end
    end
  end

  defp parse(input) do
    case parse_resource(input) do
      {:ok, _} = ok -> ok
      :error -> {:error, :bad_acct}
    end
  end

  defp fetch_jrd(host, resource) do
    url =
      "https://#{host}/.well-known/webfinger?resource=" <> URI.encode_www_form(resource)

    headers = [
      {"accept", "application/jrd+json, application/json"},
      {"user-agent", "sukhi-fedi/0.1.0"}
    ]

    cond do
      not SukhiShared.UrlGuard.safe?(url) ->
        # `host` comes from what was typed or mentioned (attacker-controlled
        # via a mention / search), so refuse internal / non-https targets (SSRF).
        {:error, :blocked_host}

      true ->
        do_fetch_jrd(url, headers, resource)
    end
  end

  defp do_fetch_jrd(url, headers, resource) do
    # `redirect: false` — a 30x Location could otherwise bounce us from a
    # public host to an internal one, past the guard above.
    case SukhiFedi.Fedi.HttpFetch.capped_get(url,
           headers: headers,
           redirect: false,
           receive_timeout: @timeout_ms
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        JSON.decode(body)

      {:ok, %{status: status}} ->
        Logger.warning("WebFinger #{resource}: HTTP #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("WebFinger #{resource}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp pick_self(%{"links" => links}) when is_list(links) do
    case Enum.find(links, &self_link?/1) do
      %{"href" => href} when is_binary(href) -> {:ok, href}
      _ -> {:error, :no_self_link}
    end
  end

  defp pick_self(_), do: {:error, :no_links}

  defp self_link?(%{"rel" => "self", "type" => type}) when is_binary(type) do
    String.contains?(type, "activity+json") or String.contains?(type, "ld+json")
  end

  defp self_link?(%{"rel" => "self"}), do: true
  defp self_link?(_), do: false
end
