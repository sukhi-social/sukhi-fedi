# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.MapPeersController do
  @moduledoc """
  `/admin/map_peers` — 公開ページ `/map` の「連合の宇宙図」に名前を
  載せてよいインスタンスの allow-list を手入れする。bubble_instances と
  同じ作り: 手で足すか、既に連合している host を検索して一押しで足す。
  """

  import Plug.Conn

  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.MapPeers
  alias SukhiFedi.Web.Admin.Render

  def index(conn) do
    q = conn.params["q"]
    current = MapPeers.list()
    current_domains = MapSet.new(current, & &1.domain)

    suggestions =
      case q do
        nil -> []
        _ -> Enum.reject(Moderation.known_domains(q, limit: 50), &MapSet.member?(current_domains, &1))
      end

    Render.send_page(conn, "map_peers/index.html.eex",
      page_title: "Universe map",
      current: current,
      suggestions: suggestions,
      q: q || "",
      searched: not is_nil(q)
    )
  end

  def create(conn) do
    domain = (conn.body_params["domain"] || "") |> String.trim() |> String.downcase()

    if domain == "" do
      conn
      |> Render.put_flash(:error, "Domain required.")
      |> redirect("/admin/map_peers")
    else
      case MapPeers.add(domain, conn.assigns.admin.id) do
        {:ok, _} ->
          conn
          |> Render.put_flash(:info, "#{domain} now appears on the universe map.")
          |> redirect("/admin/map_peers")

        {:error, reason} ->
          conn
          |> Render.put_flash(:error, "Add failed: #{inspect(reason)}.")
          |> redirect("/admin/map_peers")
      end
    end
  end

  def remove(conn, domain) do
    case MapPeers.remove(domain) do
      {:ok, _} ->
        conn
        |> Render.put_flash(:info, "Removed #{domain} from the universe map.")
        |> redirect("/admin/map_peers")

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp redirect(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end
end
