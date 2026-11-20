# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.StreamingSseController do
  @moduledoc """
  Server-Sent Events half of the Mastodon streaming API.

      GET /api/v1/streaming/user               — the account's user stream
      GET /api/v1/streaming/user/notification  — notifications only

  Mastodon clients that prefer `EventSource` over a WebSocket connect
  here. Each frame is

      event: <type>
      data: <JSON>

  Right now the `user` stream carries `notification` events (follow,
  favourite, mention, reaction) — the same ones the WebSocket `user`
  stream gets, since both subscribe to the gateway broadcaster's `:home`
  feed. The connection is held open as a chunked `text/event-stream`; a
  comment heartbeat every 30s keeps idle proxies from dropping it and
  lets us notice a client that has gone away (the chunk write fails).

  The bearer is verified here directly — the gateway shares the store, so
  no round-trip to a plugin node (same as the WebSocket entry point).
  """

  import Plug.Conn

  alias SukhiFedi.Addons.Streaming.Registry
  alias SukhiFedi.OAuth
  alias SukhiFedi.Web.BearerToken

  @heartbeat_ms 30_000

  @doc "Full user stream: every event for the account."
  def user(conn, _opts), do: stream(conn, nil)

  @doc "Filtered user stream: only `notification` events."
  def user_notification(conn, _opts), do: stream(conn, "notification")

  defp stream(conn, event_filter) do
    case authenticate(conn) do
      {:ok, account_id} ->
        Registry.subscribe(:home, account_id)

        conn =
          conn
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          # Proxies (nginx) often buffer text/event-stream; opt out.
          |> put_resp_header("x-accel-buffering", "no")
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)

        schedule_heartbeat()
        loop(conn, event_filter)

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(%{error: "This method requires an authenticated user"}))
    end
  end

  defp loop(conn, event_filter) do
    receive do
      {:stream_event, _label, %{event: event, payload: payload}} ->
        cond do
          event_filter && event != event_filter ->
            loop(conn, event_filter)

          true ->
            case chunk(conn, frame(event, payload)) do
              {:ok, conn} -> loop(conn, event_filter)
              {:error, _reason} -> conn
            end
        end

      :heartbeat ->
        schedule_heartbeat()
        # A comment line keeps the stream warm and surfaces a dead client.
        case chunk(conn, ":thump\n\n") do
          {:ok, conn} -> loop(conn, event_filter)
          {:error, _reason} -> conn
        end
    end
  end

  @doc """
  Build one SSE frame. A binary payload passes through (it's already the
  client-facing string); a map is JSON-encoded. Public for testing the
  wire format.
  """
  @spec frame(String.t(), term()) :: iodata()
  def frame(event, payload) do
    data = if is_binary(payload), do: payload, else: JSON.encode!(payload)
    "event: #{event}\ndata: #{data}\n\n"
  end

  defp authenticate(conn) do
    with token when is_binary(token) <- BearerToken.extract(conn),
         {:ok, %{account: %{id: account_id}}} <- OAuth.verify_bearer(token) do
      {:ok, account_id}
    else
      _ -> :error
    end
  end

  defp schedule_heartbeat, do: Process.send_after(self(), :heartbeat, @heartbeat_ms)
end
