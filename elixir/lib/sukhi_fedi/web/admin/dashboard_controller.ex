# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.DashboardController do
  @moduledoc "Landing page for `/admin`: at-a-glance counts."

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, InstanceBlock, Report}
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
      pull: pull
    )
  end
end
