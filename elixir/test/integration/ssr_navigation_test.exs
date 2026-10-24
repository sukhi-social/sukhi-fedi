# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.SSRNavigationTest do
  @moduledoc """
  The router's side of SSR: SvelteKit's `<path>/__data.json` requests
  (client-side navigation) must reach the renderer, and stay a 404
  where there is none. Goes through the whole router, which needs the
  app up (rate limiting sits in the pipeline), hence integration.
  """

  use SukhiFedi.IntegrationCase, async: false
  use Plug.Test

  @moduletag :integration

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Account

  setup do
    prev = System.get_env("SSR_URL")
    bypass = Bypass.open()
    System.put_env("SSR_URL", "http://localhost:#{bypass.port}")

    on_exit(fn ->
      if prev, do: System.put_env("SSR_URL", prev), else: System.delete_env("SSR_URL")
    end)

    %{bypass: bypass}
  end

  test "client-side navigation data goes to the renderer too", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/d/chai/__data.json", fn conn ->
      assert conn.query_string == "x-sveltekit-invalidated=01"
      Plug.Conn.resp(conn, 200, ~s({"type":"data"}))
    end)

    conn =
      SukhiFedi.Web.Router.call(conn(:get, "/d/chai/__data.json?x-sveltekit-invalidated=01"), [])

    assert conn.status == 200
    assert conn.resp_body == ~s({"type":"data"})
  end

  test "a page route goes to the renderer", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/d/chai", fn conn ->
      Plug.Conn.resp(conn, 200, "<h1>chai</h1>")
    end)

    conn = SukhiFedi.Web.Router.call(conn(:get, "/d/chai"), [])
    assert conn.status == 200
    assert conn.resp_body == "<h1>chai</h1>"
  end

  test "with a routes.json, a path the build does not list is a 404 without asking the renderer" do
    dir = Path.join(System.tmp_dir!(), "ssr_nav_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "routes.json"), ~s({"routes": ["/d/[slug]"]}))
    System.put_env("STATIC_BAKED_DIR", dir)

    on_exit(fn ->
      System.delete_env("STATIC_BAKED_DIR")
      File.rm_rf!(dir)
    end)

    # No Bypass.expect: a request reaching the renderer would fail the test.
    assert SukhiFedi.Web.Router.call(conn(:get, "/wp-login.php"), []).status == 404
    assert SukhiFedi.Web.Router.call(conn(:get, "/d/chai/extra"), []).status == 404
  end

  test "without SSR, a stray __data.json is a plain 404" do
    System.delete_env("SSR_URL")
    conn = SukhiFedi.Web.Router.call(conn(:get, "/d/chai/__data.json"), [])
    assert conn.status == 404
  end

  # `/@alice` → `/people/<id>` is for natadeco's front, which has no `/@`
  # route. sukhi's own web does, so the guidance must not fire there — the
  # two instances are told apart by SSR, not by the deco addon (sukhi runs
  # `ENABLED_ADDONS=all` too, so the addon is on both — 2026-09-22).
  test "with SSR (natadeco), /@alice is sent to the page its front does have" do
    account = create_account!()

    conn = SukhiFedi.Web.Router.call(conn(:get, "/@#{account.username}"), [])

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/people/#{account.id}"]
  end

  test "without SSR (sukhi), /@alice stays on sukhi's own road" do
    System.delete_env("SSR_URL")
    account = create_account!()

    conn = SukhiFedi.Web.Router.call(conn(:get, "/@#{account.username}"), [])

    refute conn.status == 302
  end

  defp create_account! do
    n = System.unique_integer([:positive])

    %Account{username: "alice_#{n}", display_name: "Alice #{n}", summary: "<p>a bio</p>"}
    |> Repo.insert!()
  end
end
