# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Admin.DashboardTemplateTest do
  @moduledoc """
  `/admin` の EEx はリクエスト時に評価されるので、構文の誤りはコンパイルでは
  出ない。ここで一度ずつ描いておく。
  """

  use ExUnit.Case, async: true

  alias SukhiFedi.Web.Admin.Render

  @now ~U[2026-10-22 03:00:00Z]

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        now: @now,
        maintenance: %{running: [], ended: []},
        queues: [],
        outbox: %{pending: 0, failed: 0, oldest_pending_s: nil},
        failures: [],
        backfill: %{done: 0, pending: 0, running: 0, failed: 0, untouched: 0}
      },
      overrides
    )
  end

  defp render(snap), do: Render.render_template("dashboard/activity.html.eex", activity: snap)

  defp run(overrides) do
    Map.merge(
      %{
        name: "refetch_actors",
        mode: "execute",
        state: "running",
        stage: "fetching",
        total: 200,
        done: 50,
        failed: 2,
        last_error: nil,
        started_at: DateTime.add(@now, -100, :second),
        updated_at: DateTime.add(@now, -2, :second),
        finished_at: nil,
        stale?: false
      },
      overrides
    )
  end

  test "何も無いときは静かです、と言う" do
    html = render(snapshot())
    assert html =~ "いまは静かです"
    assert html =~ "たまっているジョブはありません"
  end

  test "動いているメンテナンスの進み具合を出す" do
    html = render(snapshot(%{maintenance: %{running: [run(%{})], ended: []}}))
    assert html =~ "メンテナンスが 1 件、動いています"
    assert html =~ "refetch_actors"
    assert html =~ "<strong>50</strong> / 200 件（25%）"
    assert html =~ "width: 25%"
    assert html =~ "のこり目安"
    refute html =~ "進みの報告がありません"
  end

  test "件数が分からない run は件数だけ出す" do
    html = render(snapshot(%{maintenance: %{running: [run(%{total: 0, done: 7})], ended: []}}))
    assert html =~ "<strong>7</strong> 件 処理済み"
  end

  test "更新が途絶えた run は、止まったと断定せず次の一手を添える" do
    stale = run(%{stale?: true, updated_at: DateTime.add(@now, -600, :second)})
    html = render(snapshot(%{maintenance: %{running: [stale], ended: []}}))
    assert html =~ "進みの報告がありません"
    assert html =~ "SukhiFedi.Maintenance.RefetchActors.run(:execute)"
  end

  test "止まった run は理由と再実行の手を出す" do
    failed =
      run(%{state: "failed", last_error: "boom <b>", finished_at: DateTime.add(@now, -60, :second)})

    html = render(snapshot(%{maintenance: %{running: [], ended: [failed]}}))
    assert html =~ "途中で止まりました"
    assert html =~ "boom &lt;b&gt;"
    assert html =~ "もう一度実行できます"
  end

  test "ジョブキューと最近の失敗を描ける" do
    html =
      render(
        snapshot(%{
          queues: [
            %{queue: "federation", executing: 1, available: 3, scheduled: 0, retryable: 2, discarded: 1}
          ],
          failures: [
            %{
              worker: "SukhiDelivery.Workers.Deliver",
              queue: "federation",
              attempt: 8,
              discarded_at: DateTime.add(@now, -3600, :second),
              error: "timeout"
            }
          ]
        })
      )

    assert html =~ "federation"
    assert html =~ "Deliver"
    assert html =~ "timeout"
    refute html =~ "いまは静かです"
  end

  test "読めなかった部分は、読めなかったと言う" do
    html = render(snapshot(%{queues: nil, outbox: nil}))
    assert html =~ "キューの様子を読めませんでした"
    assert html =~ "配送の様子を読めませんでした"
  end

  test "送り出し待ちが長く動かないときは、原因の候補を添える" do
    html = render(snapshot(%{outbox: %{pending: 4, failed: 0, oldest_pending_s: 900}}))
    assert html =~ "送り出し待ちが 15分 動いていません"
  end
end
