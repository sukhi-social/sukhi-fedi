# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.SpaRoutesTest do
  @moduledoc """
  SPA の直リンク / リロードで開く道。

  web は fallback: 'index.html' の一枚ものなので、どの URL も
  `serve_spa/1` が拾わないと 404 になる ── アプリの中でクリックする
  ぶんには SvelteKit が捌くので、**直リンクとリロードだけ**が壊れる。
  気づきにくいので、router.ex の各所にその警告コメントが繰り返し
  置いてある。それでも 2026-08-25 に `/tomo` と `/people/:id` で
  一度踏んだので、ここに並べて留める。

  見るのは「その道を `serve_spa/1` が拾ったか」だけ。テスト環境には
  ビルドした SPA の実体が無いので、拾われた道も 404 を返す ── ただし
  本文が `frontend not built …` で、道が無いときの 404 とは区別が付く。
  中身は SPA が描くので、ここでは問わない。

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

  # 道が無いときの 404 と、拾われたが実体が無いときの 404 を分ける印。
  @not_built "frontend not built"

  # ブラウザとして来る。`/posts/:id` は Accept で行き先を分けている
  # (AP JSON なら本当の ap_id へ、Markdown を欲しがる相手には本文、
  # それ以外は SPA)ので、名乗らないと SPA の道に入らない。
  defp browser_get(path) do
    conn(:get, path)
    |> Plug.Conn.put_req_header("accept", "text/html,application/xhtml+xml")
    |> Router.call(@opts)
  end

  defp spa?(conn) do
    conn.status == 200 or (conn.status == 404 and conn.resp_body =~ @not_built)
  end

  for path <- @paths do
    test "#{path} は直リンクで開ける" do
      conn = browser_get(unquote(path))

      assert spa?(conn),
             "#{unquote(path)} を SPA が拾っていない ── router.ex に serve_spa の一行が要る"
    end
  end

  test "無い道は、ちゃんと無い ── 上の見分けが効いていること" do
    conn = browser_get("/definitely-not-a-route-xyz")
    refute spa?(conn)
  end
end
