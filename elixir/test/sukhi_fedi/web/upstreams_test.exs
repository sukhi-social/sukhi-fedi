# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.UpstreamsTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Web.Upstreams

  defp up(name, claims, cookies \\ []) do
    {:ok, m} =
      Upstreams.parse_manifest(JSON.encode!(%{"claims" => claims, "cookies" => cookies}))

    Map.merge(%{name: name, url: "http://#{name}"}, m)
  end

  defp table(ups, routes \\ ""),
    do: %{upstreams: Map.new(ups, &{&1.name, &1}), routes: Upstreams.parse_routes(routes)}

  defp who(table, method, path) do
    segs = String.split(path, "/", trim: true)

    case Upstreams.resolve(table, method, segs) do
      {:ok, %{name: n}} -> n
      :none -> nil
    end
  end

  describe "patterns" do
    test "literal, one segment, prefixed segment, rest" do
      t =
        table([
          up("w", [
            %{"path" => "/timeline"},
            %{"path" => "/tags/:tag"},
            %{"path" => "/@:acct/*"},
            %{"path" => "/css/*"}
          ])
        ])

      assert who(t, "GET", "/timeline") == "w"
      refute who(t, "GET", "/timeline/x")
      assert who(t, "GET", "/tags/cats") == "w"
      refute who(t, "GET", "/tags")
      assert who(t, "GET", "/@alice") == "w"
      assert who(t, "GET", "/@alice/followers") == "w"
      refute who(t, "GET", "/@")
      refute who(t, "GET", "/alice")
      assert who(t, "GET", "/css") == "w"
      assert who(t, "GET", "/css/a/b.css") == "w"
    end

    test "`/**` is everything, the root included" do
      t = table([up("w", [%{"path" => "/**"}])])
      assert who(t, "GET", "/") == "w"
      assert who(t, "GET", "/a/b/c") == "w"
    end

    test "methods default to GET and HEAD" do
      t = table([up("w", [%{"path" => "/compose"}, %{"path" => "/post", "methods" => ["post"]}])])
      assert who(t, "GET", "/compose") == "w"
      assert who(t, "HEAD", "/compose") == "w"
      refute who(t, "POST", "/compose")
      assert who(t, "POST", "/post") == "w"
      refute who(t, "GET", "/post")
    end
  end

  describe "dot-led paths belong to the gateway" do
    test "never resolved, even for a catch-all" do
      t = table([up("w", [%{"path" => "/**"}])])
      refute who(t, "GET", "/.env")
      refute who(t, "GET", "/.well-known/x")
      refute who(t, "GET", "/a/.git/config")
      refute who(t, "GET", "/.sukhi/web.json")
    end

    test "a claim under a dot is dropped from the manifest" do
      {:ok, m} = Upstreams.parse_manifest(JSON.encode!(%{"claims" => [%{"path" => "/.x/*"}, %{"path" => "/ok"}]}))
      assert length(m.claims) == 1
    end
  end

  describe "who answers" do
    test "config rows: the first match wins, so the order is the operator's" do
      ups = [up("lobby", [%{"path" => "/home"}]), up("next", [%{"path" => "/**"}])]

      t = table(ups, "/home=lobby,/**=next")
      assert who(t, "GET", "/home") == "lobby"
      assert who(t, "GET", "/timeline") == "next"

      t = table(ups, "/**=next,/home=lobby")
      assert who(t, "GET", "/home") == "next"
    end

    test "a row only counts when its upstream claims the path" do
      ups = [up("lobby", [%{"path" => "/home"}]), up("next", [%{"path" => "/timeline"}])]
      t = table(ups, "/**=lobby,/**=next")
      assert who(t, "GET", "/timeline") == "next"
      refute who(t, "GET", "/nothing")
    end

    test "no row, one claimant: that one" do
      t = table([up("a", [%{"path" => "/a"}]), up("b", [%{"path" => "/b"}])])
      assert who(t, "GET", "/a") == "a"
      assert who(t, "GET", "/b") == "b"
    end

    test "no row, two claimants: nobody is picked" do
      t = table([up("a", [%{"path" => "/x"}]), up("b", [%{"path" => "/x"}])])
      refute who(t, "GET", "/x")
    end

    test "a row naming an unknown upstream is skipped" do
      t = table([up("a", [%{"path" => "/**"}])], "/**=ghost")
      assert who(t, "GET", "/x") == "a"
    end
  end

  describe "config text" do
    test "WEB_UPSTREAMS" do
      assert Upstreams.parse_upstreams("a=http://a:1/, b = https://b ,bad,c=ftp://x") ==
               %{"a" => "http://a:1", "b" => "https://b"}

      assert Upstreams.parse_upstreams(nil) == %{}
    end

    test "rows after a catch-all are shadowed" do
      rows = Upstreams.parse_routes("/a=x,/**=y,/b=z")
      assert [{_, "z"}] = Upstreams.shadowed_routes(rows)
      assert Upstreams.shadowed_routes(Upstreams.parse_routes("/a=x,/**=y")) == []
    end

    test "a manifest that is not one" do
      assert Upstreams.parse_manifest("nope") == :error
      assert Upstreams.parse_manifest(~s({"claims": 3})) == :error
    end
  end
end
