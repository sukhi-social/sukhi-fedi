# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.AnnouncementsController do
  @moduledoc """
  `/admin/announcements` — write the notices the box's people see in
  their client. Local only, never federated (see `SukhiFedi.Announcements`).

  An announcement is published-or-draft and may carry an optional
  `starts_at`..`ends_at` window. Publishing is a flag, so the row's
  Publish / Unpublish toggle just flips it; editing rewrites the body
  and window. The admin enters times in their own local clock; the
  page's small script converts each to a UTC ISO instant before submit,
  so what reaches us here is always UTC (or blank) — no timezone math on
  the server, no dependency.
  """

  import Plug.Conn

  alias SukhiFedi.Announcements
  alias SukhiFedi.Web.Admin.Render

  def index(conn) do
    Render.send_page(conn, "announcements/index.html.eex",
      page_title: "Announcements",
      announcements: Announcements.list_all()
    )
  end

  def create(conn) do
    params = conn.body_params

    case Announcements.create(%{
           content: params["content"],
           published: checked?(params["published"]),
           starts_at: parse_dt(params["starts_at"]),
           ends_at: parse_dt(params["ends_at"])
         }) do
      {:ok, _} ->
        conn
        |> Render.put_flash(:info, "おしらせを保存しました。")
        |> redirect("/admin/announcements")

      {:error, _cs} ->
        conn
        |> Render.put_flash(:error, "本文が空です。なにか書いてください。")
        |> redirect("/admin/announcements")
    end
  end

  def publish(conn, id), do: set_published(conn, id, true)
  def unpublish(conn, id), do: set_published(conn, id, false)

  defp set_published(conn, id, flag) do
    case Announcements.update(id, %{published: flag}) do
      {:ok, _} ->
        msg = if flag, do: "公開しました。", else: "下書きに戻しました。"
        conn |> Render.put_flash(:info, msg) |> redirect("/admin/announcements")

      {:error, :not_found} ->
        conn |> Render.put_flash(:error, "見つかりませんでした。") |> redirect("/admin/announcements")
    end
  end

  def edit(conn, id) do
    params = conn.body_params

    case Announcements.update(id, %{
           content: params["content"],
           starts_at: parse_dt(params["starts_at"]),
           ends_at: parse_dt(params["ends_at"])
         }) do
      {:ok, _} ->
        conn |> Render.put_flash(:info, "書きなおしました。") |> redirect("/admin/announcements")

      {:error, :not_found} ->
        conn |> Render.put_flash(:error, "見つかりませんでした。") |> redirect("/admin/announcements")

      {:error, _cs} ->
        conn |> Render.put_flash(:error, "本文が空です。") |> redirect("/admin/announcements")
    end
  end

  def delete(conn, id) do
    case Announcements.delete(id) do
      {:ok, _} ->
        conn |> Render.put_flash(:info, "消しました。") |> redirect("/admin/announcements")

      {:error, :not_found} ->
        conn |> Render.put_flash(:error, "見つかりませんでした。") |> redirect("/admin/announcements")
    end
  end

  # A checkbox sends its value only when ticked; absence means draft.
  defp checked?(nil), do: false
  defp checked?(_), do: true

  # The page script sends a full UTC ISO instant ("…Z"); we parse and
  # second-truncate it. The 16-char branch completes a bare
  # "2026-06-24T15:30" (a no-JS fallback) to a full instant, treated as
  # UTC. Blank or unparseable → nil (no constraint), never a crash.
  defp parse_dt(raw) do
    case raw |> to_string() |> String.trim() do
      "" ->
        nil

      s ->
        s = if String.length(s) == 16, do: s <> ":00Z", else: s

        case DateTime.from_iso8601(s) do
          {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
          _ -> nil
        end
    end
  end

  defp redirect(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end
end
