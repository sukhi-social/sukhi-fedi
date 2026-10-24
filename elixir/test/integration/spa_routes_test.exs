# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.SpaRoutesTest do
  @moduledoc """
  SPA の直リンク / リロードで開く道。

  web は fallback: 'index.html' の一枚ものなので、どの URL も shell を
  返さないと 404 になる ── アプリの中でクリックするぶんには SvelteKit が
  捌くので、**直リンクとリロードだけ**が壊れる。気づきにくく、`/tomo` と
  `/people/:id`(2026-08-25)ほか何度も踏んだ。

  どの URL が頁かは、ビルドが出す `routes.json` が言う
  (SukhiFedi.Web.SpaRoutes)。router.ex に頁ごとの行は無い。ここでは
  「routes.json にある頁を、router が shell で返すか」を見る。テストの
  木には本物のビルドが無いので、`routes.json` と `index.html` を置いた
  仮の木を使う ── 頁の一覧は sukhi の web と natadeco の画面のぶん。

      mix test --only integration test/integration/spa_routes_test.exs
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Plug.Test

  alias SukhiFedi.Web.Router

  @opts Router.init([])

  # natadeco の画面と、sukhi の web が使う一段路。どちらも同じ shell。
  @paths [
    "/timeline",
    "/settings",
    "/search",
    "/messages",
    "/messages/1",
    "/clips",
    "/compose",
    "/notifications",
    "/bookmarks",
    "/favourites",
    "/requests",
    "/lists",
    "/lists/1",
    "/signup",
    "/hello",
    "/tomo",
    "/veranda",
    "/about",
    "/people/1",
    "/d/hinata",
    "/d/hinata/new",
    "/posts/1"
  ]

  # SvelteKit の route id。実際のビルドの `routes.json` と同じ書き方。
  @route_ids [
    "/",
    "/timeline",
    "/settings",
    "/search",
    "/messages",
    "/messages/[id]",
    "/clips",
    "/compose",
    "/notifications",
    "/bookmarks",
    "/favourites",
    "/requests",
    "/lists",
    "/lists/[id]",
    "/signup",
    "/hello",
    "/tomo",
    "/veranda",
    "/about",
    "/people/[id]",
    "/d/[slug]",
    "/d/[slug]/new"
  ]

  @shell "<!doctype html><title>shell</title>"

  setup do
    baked = Path.join(System.tmp_dir!(), "spa_routes_it_#{System.unique_integer([:positive])}")
    File.mkdir_p!(baked)
    File.write!(Path.join(baked, "index.html"), @shell)
    File.write!(Path.join(baked, "routes.json"), Jason.encode!(%{"routes" => @route_ids}))

    prev = {System.get_env("STATIC_BAKED_DIR"), System.get_env("STATIC_OVERRIDE_DIR")}
    System.put_env("STATIC_BAKED_DIR", baked)
    System.put_env("STATIC_OVERRIDE_DIR", Path.join(baked, "no-override"))

    on_exit(fn ->
      restore("STATIC_BAKED_DIR", elem(prev, 0))
      restore("STATIC_OVERRIDE_DIR", elem(prev, 1))
      File.rm_rf!(baked)
    end)
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)

  # ブラウザとして来る。`/posts/:id` は Accept で行き先を分けている
  # (AP JSON なら本当の ap_id へ、Markdown を欲しがる相手には本文、
  # それ以外は SPA)ので、名乗らないと SPA の道に入らない。
  defp browser_get(path) do
    conn(:get, path)
    |> Plug.Conn.put_req_header("accept", "text/html,application/xhtml+xml")
    |> Router.call(@opts)
  end

  # 見張りサービスの多くは HEAD で叩く。Plug.Router の `get` は GET しか
  # 拾わないので、pipeline の Plug.Head が抜けると全部 404 になる。
  defp browser_head(path) do
    conn(:head, path)
    |> Plug.Conn.put_req_header("accept", "text/html,application/xhtml+xml")
    |> Router.call(@opts)
  end

  defp spa?(conn), do: conn.status == 200

  for path <- @paths do
    test "#{path} は直リンクで開ける" do
      conn = browser_get(unquote(path))

      assert spa?(conn),
             "#{unquote(path)} を SPA が拾っていない ── routes.json の route id と SpaRoutes を見る"
    end
  end

  test "HEAD でも同じ道が開く ── 見張りに「落ちている」と読まれないこと" do
    conn = browser_head("/")

    assert spa?(conn),
           "HEAD / を SPA が拾っていない ── router.ex の pipeline に Plug.Head が要る"
  end

  test "routes.json に無い道は、ちゃんと無い" do
    conn = browser_get("/definitely-not-a-route-xyz")
    refute spa?(conn)
    assert conn.status == 404
  end

  test "頁の下の余計な段は頁ではない" do
    assert browser_get("/lists/1/extra").status == 404
  end
end
