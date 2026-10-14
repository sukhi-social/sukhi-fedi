# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.DocsTest do
  use ExUnit.Case, async: true

  alias SukhiApi.Docs

  # Real functions, so a route can capture them the way capabilities do.
  defmodule OAuthApps do
    def list_apps(_req), do: :ok
    def show(_req), do: :ok

    def create(_req), do: :ok
  end

  defmodule MastodonStatuses do
    def delete(_req), do: :ok
    def update_credentials!(_req), do: :ok
  end

  defp routes do
    [
      {:post, "/api/v1/statuses/:id/favourite", &MastodonStatuses.delete/1, scope: "write:favourites"},
      {:get, "/api/v1/apps", &OAuthApps.list_apps/1},
      {:get, "/api/v1/apps/:id", &OAuthApps.show/1},
      {:post, "/api/v1/apps", &OAuthApps.create/1},
      {:patch, "/api/v1/accounts/update_credentials", &MastodonStatuses.update_credentials!/1, scope: "write:accounts"},
      {:get, "/api/v1/ping_pong", fn _req -> :ok end}
    ]
  end

  describe "entries/1" do
    test "grouped by capability, then path, then method in the usual order" do
      assert [
               {"Docs test", "/api/v1/ping_pong", "GET"},
               {"Mastodon statuses", "/api/v1/accounts/update_credentials", "PATCH"},
               {"Mastodon statuses", "/api/v1/statuses/:id/favourite", "POST"},
               {"OAuth apps", "/api/v1/apps", "GET"},
               {"OAuth apps", "/api/v1/apps", "POST"},
               {"OAuth apps", "/api/v1/apps/:id", "GET"}
             ] == Enum.map(Docs.entries(routes()), &{&1.group, &1.path, &1.method})
    end

    test "scope is carried; a route without one is public (scope nil)" do
      by_path = Map.new(Docs.entries(routes()), &{{&1.method, &1.path}, &1})
      assert by_path[{"POST", "/api/v1/statuses/:id/favourite"}].scope == "write:favourites"
      assert by_path[{"GET", "/api/v1/apps"}].scope == nil
    end

    test "path parameters are the :segments" do
      e = Enum.find(Docs.entries(routes()), &(&1.path == "/api/v1/statuses/:id/favourite"))
      assert e.params == ["id"]
    end

    test "the summary is the function name spelled out" do
      by_name = Map.new(Docs.entries(routes()), &{&1.operation, &1})
      assert by_name["SukhiApi.DocsTest.OAuthApps.list_apps"].summary == "List apps"
      assert by_name["SukhiApi.DocsTest.MastodonStatuses.update_credentials!"].summary == "Update credentials"
    end

    test "a bare generic name borrows the resource from the path" do
      by_name = Map.new(Docs.entries(routes()), &{&1.operation, &1})
      # `show` on /api/v1/apps/:id -> the last path segment that is not a parameter
      assert by_name["SukhiApi.DocsTest.OAuthApps.show"].summary == "Show apps"
      assert by_name["SukhiApi.DocsTest.MastodonStatuses.delete"].summary == "Delete favourite"
    end

    test "the first line of an @doc wins over the name, when the docs are there" do
      # A module compiled to disk carries its docs; one defined inside a test
      # file does not, so this uses a real one: `SukhiApi.Docs.html/1`.
      [e] = Docs.entries([{:get, "/x", &Docs.html/1}])
      assert e.summary =~ "self-contained page"
      refute e.summary == "Html"
    end

    test "an anonymous fn is summarised from its path" do
      e = Enum.find(Docs.entries(routes()), &(&1.path == "/api/v1/ping_pong"))
      assert e.summary == "Ping pong"
      assert e.operation =~ ~r/^SukhiApi\.DocsTest\.get_ping_pong$/
    end
  end

  describe "group_name/1" do
    test "reads as a phrase; acronyms keep their capitals" do
      assert Docs.group_name(SukhiApi.Capabilities.MastodonStatuses) == "Mastodon statuses"
      assert Docs.group_name(SukhiApi.Capabilities.OAuthApps) == "OAuth apps"
      assert Docs.group_name(SukhiApi.Capabilities.OAuth) == "OAuth"
      assert Docs.group_name(SukhiApi.Capabilities.ApiDocs) == "API docs"
      assert Docs.group_name(SukhiApi.Capabilities.Admin) == "Admin"
    end
  end

  describe "html/1" do
    test "counts, rows, scope badges and :params" do
      html = Docs.html(routes())
      assert html =~ "6 endpoints in 3 groups"
      assert html =~ ~s(<b class="m post">POST</b>)
      assert html =~ ~s(<span class="scope">write:favourites</span>)
      assert html =~ ~s(<span class="scope pub">public</span>)
      assert html =~ "<i>:id</i>"
      assert html =~ ~s(id="oauth-apps")
    end

    test "is self-contained: no external script, stylesheet or font" do
      html = Docs.html(routes())
      refute html =~ ~r/<(script|link)[^>]+(src|href)=["']https?:/
      refute html =~ "@import"
    end

    test "escapes what routes and docs contain" do
      evil = [{:get, "/x/<b>&\"q\"", &OAuthApps.show/1, scope: "a<b"}]
      html = Docs.html(evil)
      assert html =~ "/x/&lt;b&gt;&amp;&quot;q&quot;"
      assert html =~ "a&lt;b"
      refute html =~ "/x/<b>"
    end

    test "is deterministic" do
      assert Docs.html(routes()) == Docs.html(Enum.reverse(routes()))
    end
  end

  describe "openapi/2" do
    test "is a minimal 3.1 document that encodes to JSON" do
      doc = Docs.openapi(routes(), "1.2.3")
      assert {:ok, _} = JSON.decode(JSON.encode!(doc))
      assert doc["openapi"] == "3.1.0"
      assert doc["info"] == %{"title" => "sukhi-fedi API", "version" => "1.2.3"}
    end

    test "paths use {param}; methods are lower case; both methods on one path" do
      paths = Docs.openapi(routes(), "x")["paths"]
      assert Map.has_key?(paths, "/api/v1/statuses/{id}/favourite")
      assert paths["/api/v1/apps"] |> Map.keys() |> Enum.sort() == ["get", "post"]

      op = paths["/api/v1/statuses/{id}/favourite"]["post"]
      assert op["parameters"] == [%{"name" => "id", "in" => "path", "required" => true, "schema" => %{"type" => "string"}}]
      assert op["tags"] == ["Mastodon statuses"]
      assert op["operationId"] == "SukhiApi.DocsTest.MastodonStatuses.delete"
    end

    test "a scoped route requires its scope; a public one declares no security; scopes are listed once, sorted" do
      doc = Docs.openapi(routes(), "x")
      assert doc["paths"]["/api/v1/statuses/{id}/favourite"]["post"]["security"] == [%{"oauth2" => ["write:favourites"]}]
      refute Map.has_key?(doc["paths"]["/api/v1/apps"]["get"], "security")
      refute Map.has_key?(doc["paths"]["/api/v1/apps"]["get"], "parameters")

      scopes = doc["components"]["securitySchemes"]["oauth2"]["flows"]["authorizationCode"]["scopes"]
      assert Map.keys(scopes) |> Enum.sort() == ["write:accounts", "write:favourites"]
    end
  end
end
