# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.BenchTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Graph.Bench

  test "stats are in milliseconds, percentiles by rank" do
    s = Bench.stats(Enum.map(1..100, &(&1 * 1000)))
    assert %{"n" => 100, "p50" => 51.0, "p95" => 96.0, "max" => 100.0} = s
  end

  defp result(label, p95),
    do: %{
      "label" => label,
      "metrics" => %{"public_ms" => %{"p50" => 1.0, "p95" => p95}, "tokens" => %{"total" => 5}},
      "size" => %{"graph_dir_mb" => 3}
    }

  test "the table flags only a real regression: >25% and >2 ms" do
    md = Bench.markdown(result("pr", 10.0), result("main", 5.0))
    assert md =~ "+100% ⚠"

    refute Bench.markdown(result("pr", 1.4), result("main", 1.0)) =~ "⚠"
    refute Bench.markdown(result("pr", 11.0), result("main", 10.0)) =~ "⚠"
    assert Bench.markdown(result("pr", 4.0), nil) =~ "| public_ms | 1.00 | 4.00 |"
  end
end
