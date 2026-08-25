# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.WebfingerControllerTest do
  @moduledoc """
  DB を要らない口だけ ── host-meta の札と、resource 無しの断り。
  実アカウントを引く道は `test/integration/deco_federation_test.exs` の側。
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias SukhiFedi.Web.WebfingerController

  setup do
    prev = Application.get_env(:sukhi_fedi, :domain)
    Application.put_env(:sukhi_fedi, :domain, "test.example")
    on_exit(fn -> Application.put_env(:sukhi_fedi, :domain, prev) end)
    :ok
  end

  test "host-meta は webfinger を指す XRD を返す" do
    conn = WebfingerController.host_meta(conn(:get, "/.well-known/host-meta"), [])

    assert conn.status == 200
    assert {"content-type", "application/xrd+xml; charset=utf-8"} in conn.resp_headers

    assert conn.resp_body =~ ~s(xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0")

    assert conn.resp_body =~
             ~s(<Link rel="lrdd" template="https://test.example/.well-known/webfinger?resource={uri}"/>)
  end

  test "resource が無ければ 400" do
    conn =
      conn(:get, "/.well-known/webfinger")
      |> Plug.Conn.fetch_query_params()
      |> WebfingerController.call([])

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] =~ "resource"
  end
end
