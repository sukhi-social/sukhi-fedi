# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.HealthTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias SukhiFedi.Web.Router

  test "GET /up is a liveness check with a stable empty dependency surface" do
    conn = Router.call(conn(:get, "/up"), Router.init([]))

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end
end
