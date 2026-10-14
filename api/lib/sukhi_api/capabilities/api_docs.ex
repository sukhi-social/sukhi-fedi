# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.ApiDocs do
  @moduledoc """
  The API reference, served by the API itself.

      GET /api/docs        a compact, filterable page (HTML)
      GET /api/docs.json   the same as a minimal OpenAPI 3.1 document

  Both are public and are built on request from the routes this node is
  actually serving (`SukhiApi.Registry.routes/0`), so a capability or addon
  that is switched off is not listed, and nothing here can drift from the
  code. All the work is in `SukhiApi.Docs`; this module only serves it.
  """

  use SukhiApi.Capability

  alias SukhiApi.{Docs, Registry}

  @impl true
  def routes do
    [
      {:get, "/api/docs", &reference/1},
      {:get, "/api/docs.json", &openapi_document/1}
    ]
  end

  def reference(_req), do: respond("text/html; charset=utf-8", Docs.html(Registry.routes()))

  def openapi_document(_req) do
    doc = Docs.openapi(Registry.routes(), version())
    respond("application/json", JSON.encode!(doc))
  end

  defp version do
    case Application.spec(:sukhi_api, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "0"
    end
  end

  # Short-lived: cheap to rebuild, and a deploy changes it.
  defp respond(content_type, body) do
    {:ok,
     %{
       status: 200,
       body: body,
       headers: [
         {"content-type", content_type},
         {"cache-control", "public, max-age=300"}
       ]
     }}
  end
end
