# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.OAuthApps do
  @moduledoc """
  Mastodon-compatible OAuth client app endpoints.

      POST /api/v1/apps                      (public)        register a client
      GET  /api/v1/apps/verify_credentials   scope read      look up the app behind a token
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc

  @gateway SukhiFedi.OAuth

  @impl true
  def routes do
    [
      {:post, "/api/v1/apps", &create/1},
      {:get, "/api/v1/apps/verify_credentials", &verify_credentials/1, scope: "read"}
    ]
  end

  def create(req) do
    with {:ok, body} <- decode_body(req),
         params = build_register_params(body),
         {:ok, %{app: app, client_secret: secret}} <-
           GatewayRpc.run(@gateway, :register_app, [params]) do
      ok(200, %{
        id: to_string(app.id),
        name: app.name,
        website: app.website,
        redirect_uri: app.redirect_uri,
        client_id: app.client_id,
        client_secret: secret,
        vapid_key: nil
      })
    else
      {:error, {:validation, errors}} ->
        ok(422, %{error: "validation_failed", details: errors})

      {:unavailable, why} ->
        ok(503, GatewayRpc.unavailable_body(why))

      {:error, :bad_json} ->
        ok(400, %{error: "invalid_json"})

      _ ->
        ok(400, %{error: "invalid_request"})
    end
  end

  def verify_credentials(req) do
    %{current_app: app} = req[:assigns]

    ok(200, %{
      id: to_string(app.id),
      name: app.name,
      website: app.website,
      redirect_uri: app.redirect_uri,
      vapid_key: nil
    })
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp build_register_params(body) when is_map(body) do
    %{
      "name" => body["client_name"] || body["name"],
      "redirect_uris" => body["redirect_uris"] || "urn:ietf:wg:oauth:2.0:oob",
      "scopes" => body["scopes"] || "read",
      "website" => body["website"]
    }
  end

  defp decode_body(req) do
    headers = req[:headers] || []
    ct = Enum.find_value(headers, "", fn {k, v} ->
      if String.downcase(to_string(k)) == "content-type", do: to_string(v), else: nil
    end)

    case req[:body] do
      nil -> {:ok, %{}}
      "" -> {:ok, %{}}
      body when is_binary(body) ->
        cond do
          String.contains?(ct, "application/json") ->
            case JSON.decode(body) do
              {:ok, %{} = m} -> {:ok, m}
              _ -> {:error, :bad_json}
            end

          String.contains?(ct, "application/x-www-form-urlencoded") ->
            {:ok, URI.decode_query(body)}

          true ->
            case JSON.decode(body) do
              {:ok, %{} = m} -> {:ok, m}
              _ -> {:ok, URI.decode_query(body)}
            end
        end
    end
  end

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
