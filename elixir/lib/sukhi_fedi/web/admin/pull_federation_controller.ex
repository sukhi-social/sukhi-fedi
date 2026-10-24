# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.PullFederationController do
  @moduledoc """
  `/admin/pull_federation` — how Pull Federation is doing: what the last day
  looked like, where things stand now, which peers are involved, and (the
  point of it) how many POSTs became notifications. All the reading is in
  `SukhiFedi.PullFederation.Stats`; this only lays it out.

  `/admin/pull_federation.json` returns the same numbers for scripts.
  """

  import Plug.Conn

  alias SukhiFedi.PullFederation.Stats
  alias SukhiFedi.Web.Admin.Render

  @hours 24

  def index(conn) do
    totals = Stats.totals(@hours)

    Render.send_page(conn, "pull_federation/index.html.eex",
      page_title: "Pull Federation",
      hours: @hours,
      d: Stats.derive(totals),
      gauges: Stats.gauges(),
      hourly: Stats.hourly(@hours),
      peers: Stats.peers(30)
    )
  end

  def json(conn) do
    totals = Stats.totals(@hours)

    body = %{
      window_hours: @hours,
      derived: Stats.derive(totals),
      totals: totals,
      gauges: Stats.gauges(),
      hourly:
        Enum.map(
          Stats.hourly(@hours),
          &%{hour: NaiveDateTime.to_iso8601(&1.hour), kinds: &1.kinds}
        ),
      kinds: SukhiShared.PullStats.kinds()
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(body))
  end
end
