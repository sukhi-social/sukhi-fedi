# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.WebfingerController do
  @moduledoc """
  `/.well-known/webfinger` handler.

  Elixir-native implementation: Accounts lookup + JRD build + single
  ETS write. No NATS round-trip.
  """

  import Plug.Conn

  alias SukhiFedi.{Accounts, Cache.Ets}

  @ttl_seconds 600

  def call(conn, _opts) do
    case conn.params["resource"] do
      nil ->
        send_resp(conn, 400, JSON.encode!(%{error: "missing 'resource' query parameter"}))

      resource ->
        handle_resource(conn, resource)
    end
  end

  defp handle_resource(conn, resource) do
    case Ets.get(:webfinger, resource) do
      {:ok, cached} ->
        send_jrd(conn, 200, cached)

      :miss ->
        case build_jrd(resource) do
          {:ok, jrd} ->
            Ets.put(:webfinger, resource, jrd, @ttl_seconds)
            send_jrd(conn, 200, jrd)

          {:error, :not_found} ->
            send_resp(conn, 404, JSON.encode!(%{error: "not_found"}))

          {:error, reason} ->
            send_resp(conn, 400, JSON.encode!(%{error: inspect(reason)}))
        end
    end
  end

  # `acct:user@domain` — Mastodon-style webfinger lookup.
  defp build_jrd("acct:" <> rest) do
    case String.split(rest, "@", parts: 2) do
      [user, domain] ->
        our_domain = SukhiFedi.Config.domain!()

        if domain == our_domain do
          lookup_local_actor(user, domain)
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :invalid_resource}
    end
  end

  # `https://.../users/:name` — some servers (iceshrimp, fedify-based)
  # reverse-webfinger from an actor URL back to the canonical acct
  # before trusting actor JSON. Rejecting this causes the remote
  # profile to be marked "unknown" and downstream deref to be skipped.
  defp build_jrd("http://" <> _ = url), do: build_jrd_from_url(url)
  defp build_jrd("https://" <> _ = url), do: build_jrd_from_url(url)

  defp build_jrd(_), do: {:error, :invalid_resource}

  defp build_jrd_from_url(url) do
    our_domain = SukhiFedi.Config.domain!()

    with %URI{host: host, path: path} when host == our_domain and is_binary(path) <-
           URI.parse(url),
         ["users", username] <- path |> String.trim("/") |> String.split("/") do
      lookup_local_actor(username, our_domain)
    else
      _ -> {:error, :not_found}
    end
  end

  @deco_suffix "-deco"

  defp lookup_local_actor(username, domain) do
    if String.ends_with?(username, @deco_suffix) and
         SukhiFedi.Addon.Registry.enabled?(:deco) do
      lookup_deco_actor(String.trim_trailing(username, @deco_suffix), username, domain)
    else
      lookup_person_actor(username, domain)
    end
  end

  defp lookup_deco_actor(slug, username, domain) do
    case SukhiFedi.Addons.Deco.get_deco_record(slug) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, deco} ->
        actor_url = SukhiFedi.AP.GroupJson.actor_uri(deco)

        {:ok,
         %{
           subject: "acct:#{username}@#{domain}",
           aliases: [actor_url],
           links: [
             %{rel: "self", type: "application/activity+json", href: actor_url},
             %{rel: "http://webfinger.net/rel/profile-page", type: "text/html", href: actor_url}
           ]
         }}
    end
  end

  defp lookup_person_actor(username, domain) do
    case Accounts.get_account_by_username(username) do
      nil ->
        {:error, :not_found}

      account ->
        actor_url = "https://#{domain}/users/#{account.username}"

        {:ok,
         %{
           subject: "acct:#{username}@#{domain}",
           aliases: [actor_url],
           links: [
             %{
               rel: "self",
               type: "application/activity+json",
               href: actor_url
             },
             %{
               rel: "http://webfinger.net/rel/profile-page",
               type: "text/html",
               href: actor_url
             }
           ]
         }}
    end
  end

  defp send_jrd(conn, status, jrd) do
    conn
    |> put_resp_content_type("application/jrd+json")
    |> send_resp(status, JSON.encode!(jrd))
  end
end
