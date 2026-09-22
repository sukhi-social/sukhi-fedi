# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.BackfillTemplateTest do
  @moduledoc """
  `/admin/backfill` の EEx はリクエスト時に評価されるので、構文の誤りは
  コンパイルでは出ない。ここで一度描いておく。
  """

  use ExUnit.Case, async: true

  alias SukhiFedi.Schema.Account
  alias SukhiFedi.Web.Admin.Render

  test "done と untouched の行を描ける" do
    rows = [
      %Account{
        username: "lapy",
        domain: "ff.lapy.link",
        actor_uri: "https://ff.lapy.link/users/x",
        backfill_state: "done",
        backfill_mirrored: 12,
        backfill_attempted_at: ~U[2026-09-22 10:00:00Z],
        backfill_error: nil
      },
      %Account{
        username: "quiet",
        domain: "quiet.example",
        actor_uri: "https://quiet.example/users/quiet",
        backfill_state: nil,
        backfill_mirrored: 0
      }
    ]

    counts = %{done: 1, pending: 0, running: 0, failed: 0, untouched: 1}

    html = Render.render_template("backfill/index.html.eex", rows: rows, counts: counts)

    assert html =~ "@lapy@ff.lapy.link"
    assert html =~ ">done<"
    assert html =~ ">untouched<"
    assert html =~ "2026-09-22T10:00:00Z"
  end

  test "誰も follow していなければ空の案内を出す" do
    html =
      Render.render_template("backfill/index.html.eex",
        rows: [],
        counts: %{done: 0, pending: 0, running: 0, failed: 0, untouched: 0}
      )

    assert html =~ "Not following anyone remote yet."
  end
end
