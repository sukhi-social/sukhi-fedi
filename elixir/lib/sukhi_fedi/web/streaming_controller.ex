# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.StreamingController do
  @moduledoc """
  Entry point for `/api/v1/streaming`.

  The gateway shares the store with the api plugin node, so the OAuth
  bearer is verified here directly via `SukhiFedi.OAuth.verify_bearer/1`
  rather than round-tripping to a plugin. On success the connection is
  upgraded to a WebSocket handled by `SukhiFedi.Web.StreamingSocket`.

  Mastodon clients pass the token as the `access_token` query param
  (browsers can't set `Authorization` on a WebSocket handshake); an
  `Authorization: Bearer` header is accepted too for non-browser clients.
  """

  import Plug.Conn

  alias SukhiFedi.OAuth
  alias SukhiFedi.Web.BearerToken
  alias SukhiFedi.Web.StreamingSocket

  # > 2× the socket's heartbeat interval, so a live connection answering
  # pings never trips the idle timeout.
  @idle_timeout_ms 90_000

  def connect(conn, _opts) do
    if websocket_upgrade?(conn) do
      authenticate_and_upgrade(conn)
    else
      send_resp(conn, 426, "this endpoint requires a websocket upgrade")
    end
  end

  defp authenticate_and_upgrade(conn) do
    with token when is_binary(token) <- BearerToken.extract(conn),
         {:ok, %{account: account}} <- OAuth.verify_bearer(token) do
      state = %{
        account_id: account && account.id,
        initial_stream: conn.query_params["stream"]
      }

      upgrade_adapter(conn, :websocket, {StreamingSocket, state, timeout: @idle_timeout_ms})
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(%{error: "This method requires an authenticated user"}))
    end
  end

  defp websocket_upgrade?(conn) do
    conn
    |> get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end
end
