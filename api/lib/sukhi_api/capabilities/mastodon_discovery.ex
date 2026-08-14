# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonDiscovery do
  @moduledoc """
  "Discovery" surface — trending content, suggested accounts, custom
  emojis. Each route currently returns an empty list / minimal payload
  so Mastodon clients (Moshidon, Ivory, Tusky, ...) stop logging 404s
  on first launch. Real implementations will land alongside the
  background aggregation jobs that compute the data.

  Endpoints:

      GET /api/v1/trends            (alias for /api/v1/trends/tags)
      GET /api/v1/trends/tags       — [Tag]
      GET /api/v1/trends/statuses   — [Status]
      GET /api/v1/trends/links      — [PreviewCard]
      GET /api/v1/suggestions       — v1 shape: [Account]
      GET /api/v2/suggestions       — v2 shape: [%{source, account}]
      GET /api/v1/custom_emojis     — [CustomEmoji]
  """

  use SukhiApi.Capability, addon: :mastodon_api

  @impl true
  def routes do
    [
      {:get, "/api/v1/trends", &empty_list/1},
      {:get, "/api/v1/trends/tags", &empty_list/1},
      {:get, "/api/v1/trends/statuses", &empty_list/1},
      {:get, "/api/v1/trends/links", &empty_list/1},
      {:get, "/api/v1/suggestions", &empty_list/1},
      {:get, "/api/v2/suggestions", &empty_list/1}
    ]
  end

  def empty_list(_req) do
    {:ok,
     %{
       status: 200,
       body: "[]",
       headers: [{"content-type", "application/json"}]
     }}
  end
end
