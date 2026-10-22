# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.MaintenanceProgressTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Maintenance.Progress
  alias SukhiFedi.Schema.MaintenanceRun
  alias SukhiFedi.ServerActivity

  defp row(%Progress{id: id}), do: Repo.get!(MaintenanceRun, id)

  test "start → map → finish が行に残る" do
    run = Progress.start("refetch_actors", :execute, 3, "fetching")
    assert %{state: "running", total: 3, done: 0, stage: "fetching"} = row(run)

    {results, run} =
      Progress.map(run, [:refetched, :skipped, :error], fn r -> r end)

    assert results == [:refetched, :skipped, :error]
    Progress.finish(run, %{refetched: 1, mode: :execute})

    assert %{state: "done", done: 3, failed: 1, finished_at: %DateTime{}} = row(run)
    assert row(run).summary == %{"refetched" => 1, "mode" => "execute"}
  end

  test "書き込みは間引かれ、finish で必ず最終値が入る" do
    run = Progress.start("x", :execute, 1000)
    run = Enum.reduce(1..500, run, fn _, run -> Progress.step(run, :ok) end)
    # 1 秒以内の連打では、行はまだ初期値のまま
    assert row(run).done == 0
    Progress.finish(run)
    assert row(run).done == 500
  end

  test "stage は直ちに書き、件数を数え直す" do
    run = Progress.start("x", :execute, 5, "one")
    run = Progress.step(run, :ok)
    run = Progress.stage(run, "two", 9)
    assert %{stage: "two", total: 9, done: 0} = row(run)
  end

  test "track は例外で failed にして再送出する" do
    assert_raise RuntimeError, "boom", fn ->
      Progress.track("x", :execute, 1, nil, fn _run -> raise "boom" end)
    end

    assert %{state: "failed", last_error: "boom"} = hd(Progress.recent(1))
  end

  test "ServerActivity.snapshot: 動いている run と終わった run を分ける" do
    run = Progress.start("wipe_remote", :execute, 10, "deleting")
    done = Progress.start("refetch_actors", :execute, 1)
    Progress.finish(done)

    snap = ServerActivity.snapshot()
    assert [%{name: "wipe_remote", stale?: false}] = snap.maintenance.running
    assert [%{name: "refetch_actors"}] = snap.maintenance.ended
    refute ServerActivity.quiet?(snap)

    Progress.finish(run)
    assert ServerActivity.quiet?(ServerActivity.snapshot())
  end

  test "ServerActivity.snapshot: キュー・outbox・失敗を読める" do
    snap = ServerActivity.snapshot()
    assert is_list(snap.queues)
    assert %{pending: 0, failed: 0} = snap.outbox
    assert snap.failures == []
  end

  test "更新の途絶えた run は stale? になる" do
    run = Progress.start("x", :execute, 1)
    old = DateTime.add(DateTime.utc_now(), -1000, :second) |> DateTime.truncate(:second)
    Repo.update_all(MaintenanceRun, set: [updated_at: old])

    assert [%{stale?: true}] = ServerActivity.snapshot().maintenance.running
    _ = run
  end
end
