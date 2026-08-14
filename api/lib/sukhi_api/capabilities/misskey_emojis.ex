# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MisskeyEmojis do
  @moduledoc """
  Misskey custom emoji directory endpoints.

      POST /api/emojis
      GET  /api/emojis
      POST /api/emoji
      GET  /api/emoji

  Returns custom emojis registered on the instance in Misskey format.
  """

  use SukhiApi.Capability, addon: :misskey_api

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.MisskeyEmoji

  @impl true
  def routes do
    [
      {:post, "/api/emojis", &emojis/1},
      {:get, "/api/emojis", &emojis/1},
      {:post, "/api/emoji", &emoji/1},
      {:get, "/api/emoji", &emoji/1}
    ]
  end

  def emojis(_req) do
    case GatewayRpc.call(SukhiFedi.CustomEmojis, :list_local, []) do
      {:ok, list} when is_list(list) ->
        ok(200, %{emojis: MisskeyEmoji.render_list(list)})

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      {:error, {:badrpc, reason}} ->
        ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})

      _ ->
        ok(500, %{error: "internal_error"})
    end
  end

  def emoji(req) do
    name =
      case req[:body] do
        %{"name" => n} when is_binary(n) and n != "" -> n
        _ -> req[:query_params]["name"]
      end

    with n when is_binary(n) and n != "" <- name,
         {:ok, %{} = item} <- GatewayRpc.call(SukhiFedi.CustomEmojis, :get_local, [n]) do
      ok(200, MisskeyEmoji.render(item))
    else
      nil ->
        ok(400, %{error: "missing_name"})

      {:ok, nil} ->
        ok(404, %{error: "emoji_not_found"})

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      {:error, {:badrpc, reason}} ->
        ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})

      _ ->
        ok(500, %{error: "internal_error"})
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
