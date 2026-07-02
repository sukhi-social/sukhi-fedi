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

  alias SukhiFedi.{SystemMetrics, WtRelayTelemetry}
  alias SukhiFedi.Web.Admin.Render

  def index(conn) do
    Render.send_page(conn, "system/index.html.eex",
      page_title: "System",
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
end
