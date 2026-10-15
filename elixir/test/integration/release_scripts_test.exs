# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.ReleaseScriptsTest do
  @moduledoc """
  `Release.run_script/2` against a real database: the scripts run, take
  `args`, and do what their header says. (The data-heavy ones -- Delete
  fan-out, publishing notes -- are exercised by their own modules; here we
  check the ones that only touch rows.)
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import ExUnit.CaptureIO

  alias SukhiFedi.{Accounts, LocalAccounts, Release, Repo}
  alias SukhiFedi.Schema.MonitoredInstance

  defp run(name, args \\ []) do
    capture_io(fn -> send(self(), {:result, Release.run_script(name, args)}) end)
    assert_received {:result, result}
    result
  end

  test "backfill_monitored_instances adds a row for a watcher account, once" do
    {:ok, _} = Release.seed_actor("watcher-ex_test", monitored_domain: "ex.test")

    assert {:ok, [{:ok, %MonitoredInstance{domain: "ex.test"}}]} =
             run("backfill_monitored_instances")

    # Second run: on_conflict :nothing, nothing new is stored.
    run("backfill_monitored_instances")
    assert Repo.aggregate(MonitoredInstance, :count) == 1
  end

  test "backfill_followed_outboxes is a no-op with no remote follows" do
    assert {:ok, []} = run("backfill_followed_outboxes")
  end

  test "broadcast_actor_update reads its username from args" do
    name = "bcast#{System.unique_integer([:positive])}"
    {:ok, _} = LocalAccounts.create_admin(name, "long-enough-pass")
    assert Accounts.by_local_username(name)

    assert {:ok, _} = run("broadcast_actor_update", [name])
  end
end
