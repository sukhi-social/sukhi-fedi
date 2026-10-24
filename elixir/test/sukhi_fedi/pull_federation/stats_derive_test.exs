# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PullFederation.StatsDeriveTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.PullFederation.Stats

  defp t(n, sum_ms \\ 0, max_ms \\ 0), do: %{n: n, sum_ms: sum_ms, max_ms: max_ms}

  test "nothing counted gives zeros and no averages, not a crash" do
    d = Stats.derive(%{})
    assert d.saved_pct == nil
    assert d.notify_avg_ms == nil
    assert d.lag_avg_ms == nil
    assert d.applied == 0
  end

  test "saved_pct is the share of would-be POSTs that became notifications" do
    d = Stats.derive(%{"pull_routed" => t(90), "push_routed" => t(10)})
    assert d.saved_pct == 90
    assert Stats.derive(%{"push_routed" => t(5)}).saved_pct == 0
  end

  test "averages are sum over count, and the lag max is the recorded max" do
    d =
      Stats.derive(%{
        "notify_sent" => t(4, 400),
        "pull_ok" => t(2, 300),
        "activities_applied" => t(10, 5_000, 1_900),
        "stream_served" => t(5, 50)
      })

    assert d.notify_avg_ms == 100
    assert d.pull_avg_ms == 150
    assert d.lag_avg_ms == 500
    assert d.lag_max_ms == 1_900
    assert d.served_avg_ms == 10
  end
end
