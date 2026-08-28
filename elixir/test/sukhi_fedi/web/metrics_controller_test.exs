# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.MetricsControllerTest do
  # :metrics_token is application-wide, so these can't share it concurrently.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias SukhiFedi.Web.MetricsController

  # `/metrics` used to answer anyone. These cover the two doors that hold
  # it shut — the open case needs a running PromEx and is left to the
  # integration suite.

  setup do
    previous = Application.get_env(:sukhi_fedi, :metrics_token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sukhi_fedi, :metrics_token, previous),
        else: Application.delete_env(:sukhi_fedi, :metrics_token)
    end)

    :ok
  end

  defp get(path, token \\ nil) do
    conn = conn(:get, path)
    if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
  end

  describe "with no token configured" do
    setup do
      Application.delete_env(:sukhi_fedi, :metrics_token)
      :ok
    end

    test "GET /metrics is 404, not an open scrape" do
      assert MetricsController.prometheus(get("/metrics"), []).status == 404
    end

    test "GET /api/metrics is 404 too" do
      assert MetricsController.show(get("/api/metrics"), []).status == 404
    end

    test "a bearer does not open it — unconfigured means off, not guessable" do
      assert MetricsController.prometheus(get("/metrics", "anything"), []).status == 404
    end
  end

  describe "with a token configured" do
    setup do
      Application.put_env(:sukhi_fedi, :metrics_token, "correct-horse")
      :ok
    end

    test "GET /metrics without a bearer is 401" do
      assert MetricsController.prometheus(get("/metrics"), []).status == 401
    end

    test "GET /metrics with the wrong bearer is 401" do
      assert MetricsController.prometheus(get("/metrics", "wrong"), []).status == 401
    end

    # A prefix of the real token must not pass. secure_compare returns
    # false on a length mismatch rather than leaking it through an early
    # return, but the behaviour is worth pinning.
    test "a prefix of the token is 401" do
      assert MetricsController.prometheus(get("/metrics", "correct"), []).status == 401
    end
  end
end
