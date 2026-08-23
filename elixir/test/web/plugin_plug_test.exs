# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.PluginPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias SukhiFedi.Web.PluginPlug

  describe "call/2 with no nodes" do
    test "returns 503 and halts when node list is empty" do
      conn =
        conn(:get, "/api/v1/instance")
        |> Map.put(:body_params, %{})

      result = PluginPlug.call(conn, PluginPlug.init(nodes: []))

      assert result.status == 503
      assert result.halted
      assert JSON.decode!(result.resp_body) == %{"error" => "plugin_unavailable"}
    end
  end

  describe "call/2 with the plugin app in this very BEAM" do
    # combined/ assembles :sukhi_fedi + :sukhi_delivery + :sukhi_api into
    # one release, and `make dev` runs the same shape locally — so the
    # node holding the plugin app is this node. Node.connect/1 answers
    # false for an unnamed node, which used to 503 a plugin sitting right
    # here; :rpc.call/5 at the local node needs no distribution at all.
    defmodule Here do
      def handle(%{path: path}), do: {:ok, %{status: 200, body: path, headers: []}}
    end

    test "the local node counts as reachable and the call lands" do
      conn =
        conn(:get, "/api/v1/instance")
        |> Map.put(:body_params, %{})

      result = PluginPlug.call(conn, PluginPlug.init(nodes: [node()], module: Here))

      assert result.status == 200
      assert result.resp_body == "/api/v1/instance"
    end
  end

  describe "call/2 with unreachable nodes" do
    test "returns 503 when all configured nodes refuse to connect" do
      conn =
        conn(:post, "/api/v1/statuses")
        |> Map.put(:body_params, %{"status" => "hello"})

      result =
        PluginPlug.call(
          conn,
          PluginPlug.init(nodes: [:"nonexistent@invalid-host-#{:rand.uniform(999_999)}"])
        )

      assert result.status == 503
      assert result.halted
    end
  end

  describe "respond/2" do
    # A capability answering with two set-cookie headers (the OAuth
    # multi-account picker sets session_token + session_tokens together)
    # used to lose the first one: put_resp_header/3 replaces same-key
    # headers (List.keystore), so the second set-cookie silently clobbered
    # the first instead of adding a second Set-Cookie line. Bug found live
    # (2026-08-08): the picker minted a code for the chosen account, but
    # the browser's session_token cookie never actually moved, so the next
    # /oauth/authorize resolved back down to one account and skipped the
    # picker it should have shown.
    test "multiple set-cookie headers all survive, not just the last" do
      conn = conn(:get, "/oauth/authorize")

      result =
        PluginPlug.respond(conn, %{
          status: 302,
          body: "",
          headers: [
            {"location", "/somewhere"},
            {"set-cookie", "session_token=abc; Path=/"},
            {"set-cookie", "session_tokens=def; Path=/"}
          ]
        })

      cookies = for {"set-cookie", v} <- result.resp_headers, do: v
      assert length(cookies) == 2
      assert Enum.any?(cookies, &String.starts_with?(&1, "session_token=abc"))
      assert Enum.any?(cookies, &String.starts_with?(&1, "session_tokens=def"))
    end

    test "a single set-cookie still works (the common, single-account case)" do
      conn = conn(:get, "/login")

      result =
        PluginPlug.respond(conn, %{
          status: 200,
          body: "{}",
          headers: [
            {"content-type", "application/json"},
            {"set-cookie", "session_token=xyz; Path=/"}
          ]
        })

      cookies = for {"set-cookie", v} <- result.resp_headers, do: v
      assert cookies == ["session_token=xyz; Path=/"]
    end

    test "non-cookie headers still overwrite on repeat, as before" do
      conn = conn(:get, "/whatever")

      result =
        PluginPlug.respond(conn, %{
          status: 200,
          body: "",
          headers: [{"content-type", "text/plain"}, {"content-type", "text/html"}]
        })

      assert Plug.Conn.get_resp_header(result, "content-type") == ["text/html"]
    end
  end
end
