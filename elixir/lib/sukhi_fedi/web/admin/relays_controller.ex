# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.RelaysController do
  @moduledoc """
  `/admin/relays` — join and leave ActivityPub relays.

  Adding one sends a `Follow` of `as:Public` signed by *you* (this
  server has no instance actor), so the relay's answer lands as an
  `Accept` and the row flips to accepted. Leaving sends the matching
  `Undo` before dropping the row.
  """

  import Plug.Conn

  alias SukhiFedi.Relays
  alias SukhiFedi.Web.Admin.Render

  def index(conn) do
    Render.send_page(conn, "relays/index.html.eex",
      page_title: "Relays",
      relays: Relays.list()
    )
  end

  def create(conn) do
    url = (conn.body_params["url"] || "") |> String.trim()

    case url do
      "" ->
        conn
        |> Render.put_flash(:error, "Relay actor URL required.")
        |> redirect("/admin/relays")

      _ ->
        conn |> subscribe(url) |> redirect("/admin/relays")
    end
  end

  def remove(conn, id) do
    case Relays.unsubscribe(id) do
      {:ok, relay} ->
        conn
        |> Render.put_flash(:info, "Left #{relay.actor_uri}. The Undo is on its way.")
        |> redirect("/admin/relays")

      {:error, :not_found} ->
        send_resp(conn, 404, "")
    end
  end

  defp subscribe(conn, url) do
    case Relays.subscribe(url, conn.assigns.admin) do
      {:ok, relay} ->
        Render.put_flash(
          conn,
          :info,
          "Asked #{relay.actor_uri} to let us in. Waiting for its Accept."
        )

      {:error, reason} ->
        Render.put_flash(conn, :error, "Could not subscribe: #{explain(reason)}")
    end
  end

  defp explain(:unsafe_url), do: "that URL is not a public https address."
  defp explain(:unreachable), do: "could not fetch the relay's actor."
  defp explain(:no_inbox), do: "the actor there advertises no inbox."
  defp explain(:already_subscribed), do: "we are already subscribed to that relay."

  defp redirect(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end
end
