# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.SystemController do
  @moduledoc """
  `/admin/system` — host resource usage: CPU, memory, disk, and load
  average, plus the BEAM's own memory footprint. Reads
  `SukhiFedi.SystemMetrics`.

  The page renders an initial snapshot and then polls `/admin/system/sample`
  every couple of seconds (htmx) so the numbers stay live without a
  full reload. Disk refreshes slower than CPU/memory — disksup rescans on
  a timer, not per request.
  """

  import Plug.Conn

  alias SukhiFedi.{SystemMetrics, UpdateApproval, UpdateStatus, WtRelayTelemetry}
  alias SukhiFedi.Web.Admin.Render

  def index(conn) do
    Render.send_page(conn, "system/index.html.eex",
      page_title: "System",
      update: UpdateStatus.read(),
      metrics: SystemMetrics.snapshot(),
      wt_relay: WtRelayTelemetry.snapshot()
    )
  end

  def sample(conn) do
    Render.send_fragment(conn, "system/sample.html.eex",
      metrics: SystemMetrics.snapshot(),
      wt_relay: WtRelayTelemetry.snapshot()
    )
  end

  @approve_errors %{
    no_update: "いま承認できる更新がありません。画面を開き直してください。",
    changed: "その間に、来ている版が変わりました。もう一度、内容を確かめてください。",
    bad_commit: "版の指定が正しくありません。",
    bad_admin: "承認者の名前を記録できませんでした。",
    write_failed: "承認を箱に渡せませんでした。(記録は残っています)"
  }

  def approve(conn) do
    case UpdateApproval.approve(conn.assigns.admin, conn.body_params["commit"]) do
      :ok ->
        Render.put_flash(conn, :info, "承認しました。箱が確かめてから入れます(数分かかります)。")

      {:error, reason} ->
        Render.put_flash(conn, :error, Map.fetch!(@approve_errors, reason))
    end
    |> put_resp_header("location", "/admin/system")
    |> send_resp(302, "")
  end
end
