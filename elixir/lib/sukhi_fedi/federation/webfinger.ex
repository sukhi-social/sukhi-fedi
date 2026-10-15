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
  Look up `acct:user@host` and return the actor's `self` URL (the
  canonical AP id). Result is ETS-cached for an hour, keyed on the
  bare handle.
  """
  @spec resolve_self(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_self(acct) when is_binary(acct) do
    handle = String.trim_leading(acct, "@")

    case Ets.get(:webfinger, {:self, handle}) do
      {:ok, url} ->
        {:ok, url}

      :miss ->
        with {:ok, {_user, host}} <- split(handle),
             {:ok, jrd} <- fetch_jrd(host, handle),
             {:ok, self_url} <- pick_self(jrd) do
          Ets.put(:webfinger, {:self, handle}, self_url, @ttl_seconds)
          {:ok, self_url}
        end
    end
  end

  defp split(handle) do
    case String.split(handle, "@", parts: 2) do
      [user, host] when user != "" and host != "" -> {:ok, {user, host}}
      _ -> {:error, :bad_acct}
    end
  end

  defp fetch_jrd(host, handle) do
    url =
      "https://#{host}/.well-known/webfinger?resource=" <>
        URI.encode_www_form("acct:#{handle}")

    headers = [
      {"accept", "application/jrd+json, application/json"},
      {"user-agent", "sukhi-fedi/0.1.0"}
    ]

    cond do
      not SukhiShared.UrlGuard.safe?(url) ->
        # `host` comes from the handle (attacker-controlled via a mention /
        # search), so refuse internal / non-https targets (SSRF).
        {:error, :blocked_host}

      true ->
        do_fetch_jrd(url, headers, handle)
    end
  end

  defp do_fetch_jrd(url, headers, handle) do
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
        Logger.warning("WebFinger #{handle}: HTTP #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("WebFinger #{handle}: #{inspect(reason)}")
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
