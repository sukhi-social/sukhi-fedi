# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.DashboardController do
  @moduledoc """
  Landing page for `/admin`: what the server is doing right now.

  The page renders one snapshot and then re-fetches `/admin/activity`
  (htmx, every few seconds, only while the tab is visible) so a running
  maintenance script's progress moves on its own. Moderation counts sit
  below the live part — they change by hand, not by the second, and are
  not polled.
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, InstanceBlock, Report}
  alias SukhiFedi.ServerActivity
  alias SukhiFedi.Web.Admin.Render

  def index(conn) do
    counts = %{
      local_users: Repo.aggregate(from(a in Account, where: is_nil(a.domain)), :count),
      suspended_users:
        Repo.aggregate(from(a in Account, where: is_nil(a.domain) and not is_nil(a.suspended_at)), :count),
      open_reports: Repo.aggregate(from(r in Report, where: r.status == "open"), :count),
      instance_blocks: Repo.aggregate(InstanceBlock, :count)
    }

    pull = SukhiFedi.PullFederation.Stats.derive(SukhiFedi.PullFederation.Stats.totals(24))

    Render.send_page(conn, "dashboard.html.eex",
      page_title: "Dashboard",
      counts: counts,
      activity: ServerActivity.snapshot(),
      pull: pull
    )
  end

  @doc "The live part alone, for the htmx poll."
  def activity(conn) do
    Render.send_fragment(conn, "dashboard/activity.html.eex", activity: ServerActivity.snapshot())
  end
end
