# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.WebUpstreamsTest do
  @moduledoc """
  The router's side of the web fronts (SukhiFedi.Web.Upstreams): what a
  claim hands to a web, and what is the gateway's alone whatever a web
  says. Goes through the whole router, hence integration.
  """

  use SukhiFedi.IntegrationCase, async: false
  use Plug.Test

  @moduletag :integration

  alias SukhiFedi.Web.Router
  alias SukhiFedi.Web.Upstreams

  setup do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}"

    {:ok, m} =
      Upstreams.parse_manifest(
        ~s({"claims":[{"path":"/**"},{"path":"/compose","methods":["POST"]}]})
      )

    Upstreams.put(%{
      upstreams: %{"web-next" => Map.merge(%{name: "web-next", url: url}, m)},
      routes: Upstreams.parse_routes("/**=web-next")
    })

    on_exit(&Upstreams.clear/0)
    %{bypass: bypass}
  end

  test "a page nothing in the gateway owns goes to the claiming web", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/timeline", fn conn ->
      Plug.Conn.resp(conn, 200, "next")
    end)

    conn = Router.call(conn(:get, "/timeline"), [])
    assert conn.status == 200
    assert conn.resp_body == "next"
  end

  test "so does the front page, where the watcher addon is off", %{bypass: bypass} do
    prev = Application.get_env(:sukhi_fedi, :disabled_addons, [])
    Application.put_env(:sukhi_fedi, :disabled_addons, [:nodeinfo_monitor])
    on_exit(fn -> Application.put_env(:sukhi_fedi, :disabled_addons, prev) end)

    Bypass.expect_once(bypass, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "home") end)
    assert %{resp_body: "home"} = Router.call(conn(:get, "/"), [])
  end

  test "the front page still goes to the frontend when the watcher addon is on", %{
    bypass: bypass
  } do
    prev = Application.get_env(:sukhi_fedi, :disabled_addons, [])
    Application.put_env(:sukhi_fedi, :disabled_addons, [])
    on_exit(fn -> Application.put_env(:sukhi_fedi, :disabled_addons, prev) end)

    Bypass.expect_once(bypass, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "sns") end)
    assert %{status: 200, resp_body: "sns"} = Router.call(conn(:get, "/"), [])
  end

  test "the gateway's own doors stay the gateway's, even under a catch-all", %{bypass: _bypass} do
    # No Bypass.expect: a request reaching the web would fail the test.
    conn = Router.call(conn(:get, "/.well-known/webfinger?resource=acct:x@y"), [])
    refute conn.resp_body == "next"
    assert conn.status in [200, 400, 404]
    assert get_resp_header(conn, "x-static-source") == []
  end

  test "a dot-led path is never forwarded, web.json included", %{bypass: _bypass} do
    assert %{status: 404} = Router.call(conn(:get, "/.sukhi/web.json"), [])
    assert %{status: 404} = Router.call(conn(:get, "/.env"), [])
    assert %{status: 404} = Router.call(conn(:get, "/a/.git/config"), [])
  end

  test "nothing configured, nothing changes" do
    Upstreams.clear()
    conn = Router.call(conn(:get, "/definitely-not-a-page"), [])
    assert conn.status == 404
  end

  test "front page explains setup when no frontend route is configured" do
    previous = Application.get_env(:sukhi_fedi, :frontend_configured, false)
    Application.put_env(:sukhi_fedi, :frontend_configured, false)
    on_exit(fn -> Application.put_env(:sukhi_fedi, :frontend_configured, previous) end)

    conn = Router.call(conn(:get, "/"), [])
    assert conn.status == 200
    assert conn.resp_body =~ "Frontend setup required"
    assert conn.resp_body =~ "/etc/sukhi/instance.json"
    assert conn.resp_body =~ "SukhiFedi.Release.create_admin"
    assert conn.resp_body =~ "DATALEVIN_DIR"
    assert conn.resp_body =~ "DELIVERY_QUEUE_DB"
    refute conn.resp_body =~ "SECRET_KEY_BASE="
  end

  test "front page redirects anonymous users when configured" do
    previous_redirect = Application.get_env(:sukhi_fedi, :unauthenticated_redirect)
    previous_frontend = Application.get_env(:sukhi_fedi, :frontend_configured, false)
    Application.put_env(:sukhi_fedi, :unauthenticated_redirect, "https://about.sukhi.social")
    Application.put_env(:sukhi_fedi, :frontend_configured, true)

    on_exit(fn ->
      Application.put_env(:sukhi_fedi, :unauthenticated_redirect, previous_redirect)
      Application.put_env(:sukhi_fedi, :frontend_configured, previous_frontend)
    end)

    conn = Router.call(conn(:get, "/"), [])
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["https://about.sukhi.social"]
  end
end
