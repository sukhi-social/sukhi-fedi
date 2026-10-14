# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.ApiDocsTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Router

  setup do
    prev = Application.get_env(:sukhi_api, :enabled_addons)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    on_exit(fn -> if prev == nil, do: Application.delete_env(:sukhi_api, :enabled_addons), else: Application.put_env(:sukhi_api, :enabled_addons, prev) end)
  end

  defp get(path), do: Router.handle(%{method: "GET", path: path, headers: []})

  test "GET /api/docs is a public HTML page listing the routes this node serves" do
    {:ok, resp} = get("/api/docs")
    assert resp.status == 200
    assert {"content-type", "text/html; charset=utf-8"} in resp.headers
    assert resp.body =~ "sukhi-fedi API"
    # itself, an admin route, and the one added with the emoji import
    for path <- ["/api/docs.json", "/api/admin/accounts", "/api/admin/emojis"] do
      assert resp.body =~ path, "#{path} should be listed"
    end
  end

  test "GET /api/docs.json is the OpenAPI document of the same routes" do
    {:ok, resp} = get("/api/docs.json")
    assert resp.status == 200
    assert {"content-type", "application/json"} in resp.headers
    doc = JSON.decode!(resp.body)
    assert doc["openapi"] == "3.1.0"
    assert doc["paths"]["/api/admin/emojis"]["post"]["security"] == [%{"oauth2" => ["admin:write"]}]
    assert Map.has_key?(doc["paths"]["/api/admin/accounts/{id}"]["get"], "parameters")
  end

  test "a capability whose addon is disabled is not listed" do
    Application.put_env(:sukhi_api, :enabled_addons, [:mastodon_api])
    {:ok, resp} = get("/api/docs.json")
    doc = JSON.decode!(resp.body)
    assert Map.has_key?(doc["paths"], "/api/v1/custom_emojis")
    refute Map.has_key?(doc["paths"], "/api/admin/accounts"), "moderation addon is off"
  end
end
