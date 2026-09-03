# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.SSRTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias SukhiFedi.Web.SSR

  setup do
    prev = System.get_env("SSR_URL")
    {:ok, _} = Application.ensure_all_started(:bypass)
    bypass = Bypass.open()
    System.put_env("SSR_URL", "http://localhost:#{bypass.port}/")
    start_supervised!({Finch, name: SukhiFedi.Finch})

    on_exit(fn ->
      if prev, do: System.put_env("SSR_URL", prev), else: System.delete_env("SSR_URL")
    end)

    %{bypass: bypass}
  end

  test "unset means off" do
    System.delete_env("SSR_URL")
    refute SSR.enabled?()
    System.put_env("SSR_URL", "")
    refute SSR.enabled?()
  end

  test "the page comes from the renderer, with the reader's language", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/d/chai", fn conn ->
      assert conn.query_string == "tag=%E6%95%A3%E6%AD%A9"
      assert Plug.Conn.get_req_header(conn, "accept-language") == ["ko"]

      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, "<h1>차 데코</h1>")
    end)

    conn =
      conn(:get, "/d/chai?tag=%E6%95%A3%E6%AD%A9")
      |> put_req_header("accept-language", "ko")
      |> SSR.render()

    assert conn.status == 200
    assert conn.resp_body == "<h1>차 데코</h1>"
    assert get_resp_header(conn, "x-static-source") == ["ssr"]
    assert get_resp_header(conn, "cache-control") == ["no-cache, must-revalidate"]
    assert get_resp_header(conn, "vary") == ["accept-language"]
  end

  test "the renderer's status passes through", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/d/nai", fn conn -> Plug.Conn.resp(conn, 404, "nai") end)
    assert %{status: 404} = SSR.render(conn(:get, "/d/nai"))
  end

  test "a renderer that is down is a 503, not an empty shell", %{bypass: bypass} do
    Bypass.down(bypass)
    conn = SSR.render(conn(:get, "/"))
    assert conn.status == 503
    assert conn.resp_body =~ "もういちど"
  end
end
