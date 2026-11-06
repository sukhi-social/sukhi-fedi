# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Delivery.WorkerTest do
  use ExUnit.Case, async: true

  # Verifies that outbound deliveries flow through the worker and that
  # Signature headers are attached when an actor key is resolvable. Uses
  # Bypass to stand up a local HTTP server and asserts on the received
  # request headers.

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  describe "perform/1 — HTTP Signature headers" do
    @tag :integration
    test "outbound POST includes Signature header when actor key is found", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/inbox", fn conn ->
        assert Plug.Conn.get_req_header(conn, "signature") != []
        Plug.Conn.send_resp(conn, 202, "")
      end)

      inbox_url = "http://localhost:#{bypass.port}/inbox"

      # Integration test expects the docker-compose.test.yml stack: DB
      # seeded with an account whose username matches the object_id's
      # actor, with a private key. Without a key, signing falls through to
      # `:skip` and the POST goes out unsigned — the assertion above will
      # fail in that mode.
      args = %{
        "object_id" => 1,
        "inbox_url" => inbox_url
      }

      assert :ok = SukhiDelivery.Delivery.Worker.perform(%Oban.Job{args: args})
    end
  end
end
