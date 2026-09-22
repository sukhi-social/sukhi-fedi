# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.BackfillController do
  @moduledoc """
  `/admin/backfill` — こちらから follow している remote の、過去投稿
  backfill（相手 outbox を signed fetch で辿る）の進行状態。

  読み取りだけ。起動のたび `Federation.OutboxBackfill.pending_existing/0`
  が未着手と失敗を拾い直すので、ここで押す操作は無い。
  """

  alias SukhiFedi.Federation.OutboxBackfill
  alias SukhiFedi.Web.Admin.Render

  def index(conn) do
    Render.send_page(conn, "backfill/index.html.eex",
      page_title: "Backfill",
      rows: OutboxBackfill.list(),
      counts: OutboxBackfill.counts()
    )
  end
end
