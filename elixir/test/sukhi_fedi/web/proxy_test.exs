# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.ProxyTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias SukhiFedi.Web.Proxy
  alias SukhiFedi.Web.Upstreams.Registry

  setup do
    {:ok, _} = Application.ensure_all_started(:bypass)
    bypass = Bypass.open()
    start_supervised!({Finch, name: SukhiFedi.Finch})
    up = %{name: "web-x", url: "http://localhost:#{bypass.port}", claims: [], cookies: ["sukhi_sid"]}
    %{bypass: bypass, up: up}
  end

  defp get(path), do: conn(:get, path)

  test "GET: the page comes back, Host stays the browser's, forwarded headers are ours", %{bypass: bypass, up: up} do
    Bypass.expect_once(bypass, "GET", "/timeline", fn conn ->
      assert conn.query_string == "a=1"
      assert Plug.Conn.get_req_header(conn, "host") == ["sukhi.example"]
      assert Plug.Conn.get_req_header(conn, "x-forwarded-host") == ["sukhi.example"]
      assert Plug.Conn.get_req_header(conn, "x-forwarded-proto") == ["https"]
      # What the client claimed about itself is not believed; the peer is appended.
      assert [xff] = Plug.Conn.get_req_header(conn, "x-forwarded-for")
      assert xff == "6.6.6.6, 127.0.0.1"
      assert Plug.Conn.get_req_header(conn, "accept-language") == ["ja"]

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> Plug.Conn.resp(200, "<h1>hi</h1>")
    end)

    conn =
      %{get("/timeline?a=1") | host: "sukhi.example"}
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("x-forwarded-for", "6.6.6.6")
      |> put_req_header("accept-language", "ja")
      |> Proxy.forward(up)

    assert conn.status == 200
    assert conn.resp_body == "<h1>hi</h1>"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-static-source") == ["upstream:web-x"]
  end

  test "cookies cross by name only, both ways", %{bypass: bypass, up: up} do
    Bypass.expect_once(bypass, "GET", "/c", fn conn ->
      assert Plug.Conn.get_req_header(conn, "cookie") == ["sukhi_sid=abc"]

      conn
      |> Plug.Conn.prepend_resp_headers([
        {"set-cookie", "sukhi_sid=new; Path=/; HttpOnly"},
        {"set-cookie", "session_token=evil; Path=/"}
      ])
      |> Plug.Conn.resp(200, "ok")
    end)

    conn =
      get("/c")
      |> put_req_header("cookie", "session_token=secret; sukhi_sid=abc")
      |> Proxy.forward(up)

    assert get_resp_header(conn, "set-cookie") == ["sukhi_sid=new; Path=/; HttpOnly"]
  end

  test "no cookie reaches a web that asked for none", %{bypass: bypass, up: up} do
    Bypass.expect_once(bypass, "GET", "/c", fn conn ->
      assert Plug.Conn.get_req_header(conn, "cookie") == []
      Plug.Conn.resp(conn, 200, "ok")
    end)

    get("/c") |> put_req_header("cookie", "session_token=secret") |> Proxy.forward(%{up | cookies: []})
  end

  test "POST: the body goes through unread, and so do the status and Location", %{bypass: bypass, up: up} do
    Bypass.expect_once(bypass, "POST", "/compose", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == "text=hello&x=1"
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/x-www-form-urlencoded"]

      conn |> Plug.Conn.put_resp_header("location", "/timeline") |> Plug.Conn.resp(303, "")
    end)

    conn =
      conn(:post, "/compose", "text=hello&x=1")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Proxy.forward(up)

    assert conn.status == 303
    assert get_resp_header(conn, "location") == ["/timeline"]
  end

  test "a large body streams (more than one read)", %{bypass: bypass, up: up} do
    big = String.duplicate("x", 2_500_000)

    Bypass.expect_once(bypass, "POST", "/up", fn conn ->
      {:ok, body, conn} = read_all(conn, "")
      assert byte_size(body) == 2_500_000
      Plug.Conn.resp(conn, 200, "got")
    end)

    conn = conn(:post, "/up", big) |> put_req_header("content-type", "text/csv") |> Proxy.forward(up)
    assert conn.status == 200
  end

  defp read_all(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, b, c} -> {:ok, acc <> b, c}
      {:more, b, c} -> read_all(c, acc <> b)
    end
  end

  test "an answer with no body is still an answer", %{bypass: bypass, up: up} do
    Bypass.expect_once(bypass, "GET", "/gone", fn conn -> Plug.Conn.resp(conn, 204, "") end)
    assert %{status: 204} = Proxy.forward(get("/gone"), up)
  end

  test "the web's own status passes through", %{bypass: bypass, up: up} do
    Bypass.expect_once(bypass, "GET", "/nai", fn conn -> Plug.Conn.resp(conn, 404, "nai") end)
    conn = Proxy.forward(get("/nai"), up)
    assert conn.status == 404
    assert conn.resp_body == "nai"
  end

  test "a web that is down is a 503 page", %{bypass: bypass, up: up} do
    Bypass.down(bypass)
    conn = Proxy.forward(get("/x"), up)
    assert conn.status == 503
    assert conn.resp_body =~ "もういちど"
  end

  describe "Registry" do
    test "reads each web's web.json, and keeps the last good one when it stops answering", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/.sukhi/web.json", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"claims":[{"path":"/home"}],"cookies":["sid"]}))
      end)

      url = "http://localhost:#{bypass.port}"

      start_supervised!(
        {Registry, upstreams: %{"w" => url}, routes: [], refresh_ms: 3_600_000, retry_ms: 3_600_000}
      )

      on_exit(&SukhiFedi.Web.Upstreams.clear/0)
      Registry.refresh()

      assert {:ok, %{name: "w", cookies: ["sid"]}} = SukhiFedi.Web.Upstreams.lookup("GET", ["home"])
      assert :none = SukhiFedi.Web.Upstreams.lookup("GET", ["other"])

      Bypass.down(bypass)
      Registry.refresh()
      assert {:ok, %{name: "w"}} = SukhiFedi.Web.Upstreams.lookup("GET", ["home"])
    end

    test "unset means off" do
      System.delete_env("WEB_UPSTREAMS")
      assert :ignore = Registry.init([])
    end
  end
end
