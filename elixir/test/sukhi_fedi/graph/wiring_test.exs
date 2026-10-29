# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.WiringTest do
  use ExUnit.Case, async: false

  alias SukhiFedi.Graph.{Mirror, Workers}

  @day 86_400

  test "ttls: defaults, overrides, junk ignored" do
    assert {90 * @day, 14 * @day} == Workers.ttls(%{}, 0)

    assert {10 * @day, 2 * @day} ==
             Workers.ttls(
               %{"SUKHI_GRAPH_TTL_FOLLOWED_DAYS" => "10", "SUKHI_GRAPH_TTL_OTHER_DAYS" => "2"},
               0
             )

    assert {90 * @day, 14 * @day} ==
             Workers.ttls(
               %{"SUKHI_GRAPH_TTL_FOLLOWED_DAYS" => "abc", "SUKHI_GRAPH_TTL_OTHER_DAYS" => "-3"},
               0
             )
  end

  test "ttls halve once when the graph is over its size budget" do
    env = %{"SUKHI_GRAPH_SIZE_BUDGET_MB" => "10"}
    assert {90 * @day, 14 * @day} == Workers.ttls(env, 5 * 1_048_576)
    assert {45 * @day, 7 * @day} == Workers.ttls(env, 11 * 1_048_576)
  end

  test "an embedded object must live on its actor's host unless the author signed it" do
    ok = %{"actor" => "https://a.example/u/x", "object" => %{"id" => "https://a.example/o/1"}}

    forged = %{
      "actor" => "https://a.example/u/x",
      "object" => %{"id" => "https://evil.example/o/1"}
    }

    assert Mirror.same_origin?(ok, false)
    refute Mirror.same_origin?(forged, false)
    assert Mirror.same_origin?(forged, true)
    assert Mirror.same_origin?(%{"actor" => "x", "object" => "https://b/o"}, false)
  end

  test "the cron entries are added only when the graph is on" do
    on = fn -> Application.get_env(:sukhi_fedi, :graph) end
    prev = on.()

    try do
      Application.delete_env(:sukhi_fedi, :graph)
      refute crontab() |> Enum.any?(&match?({_, Workers.Sweep}, &1))
      refute Keyword.has_key?(SukhiFedi.Queue.oban_config()[:queues], :maintenance)

      Application.put_env(:sukhi_fedi, :graph, true)
      assert crontab() |> Enum.any?(&match?({_, Workers.Sweep}, &1))
      assert Keyword.has_key?(SukhiFedi.Queue.oban_config()[:queues], :maintenance)
    after
      if prev,
        do: Application.put_env(:sukhi_fedi, :graph, prev),
        else: Application.delete_env(:sukhi_fedi, :graph)
    end
  end

  defp crontab do
    SukhiFedi.Queue.oban_config()[:plugins]
    |> Enum.find_value(fn
      {Oban.Plugins.Cron, o} -> o[:crontab]
      _ -> nil
    end)
  end
end
