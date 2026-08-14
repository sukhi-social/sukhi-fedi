# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonEmojis do
  @moduledoc """
  Custom emoji directory listing.

      GET /api/v1/custom_emojis      (public)

  Returns only local rows (`domain IS NULL`). Inbound remote emoji
  live in the same table for reaction rendering but aren't surfaced
  here — admins shouldn't accidentally offer foreign shortcodes in
  the picker.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc

  @impl true
  def routes do
    [{:get, "/api/v1/custom_emojis", &index/1}]
  end

  def index(_req) do
    case GatewayRpc.call(SukhiFedi.CustomEmojis, :list_local, []) do
      {:ok, list} when is_list(list) ->
        ok(200, Enum.map(list, &render/1))

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      _ ->
        ok(500, %{error: "internal_error"})
    end
  end

  defp render(%{} = e) do
    %{
      shortcode: e.shortcode,
      url: e.image_url,
      static_url: e.static_url || e.image_url,
      visible_in_picker: e.visible_in_picker,
      category: e.category,
      aliases: e.aliases || []
    }
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
