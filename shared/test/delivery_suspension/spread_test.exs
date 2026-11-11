# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.SpreadTest do
  use ExUnit.Case, async: true

  alias SukhiShared.DeliverySuspension.Spread

  @peers for n <- 1..200, do: "https://peer#{n}.example/inbox"

  test "every peer is told once" do
    plan = Spread.schedule(@peers)
    assert Enum.sort(Enum.map(plan, &elem(&1, 0))) == Enum.sort(@peers)
  end

  test "the order is not the same twice" do
    firsts = for _ <- 1..30, do: @peers |> Spread.schedule() |> hd() |> elem(0)
    assert length(Enum.uniq(firsts)) > 5

    refute Enum.map(Spread.schedule(@peers), &elem(&1, 0)) ==
             Enum.map(Spread.schedule(@peers), &elem(&1, 0))
  end

  test "in any window of one second, at most per_second + 1 are sent" do
    for per_second <- [1, 5, 20] do
      delays = @peers |> Spread.schedule(per_second: per_second) |> Enum.map(&elem(&1, 1))

      worst =
        for start <- delays, reduce: 0 do
          acc -> max(acc, Enum.count(delays, &(&1 >= start and &1 < start + 1000)))
        end

      assert worst <= per_second + 1
    end
  end

  test "the delays are spread out, not one wave" do
    plan = Spread.schedule(@peers, per_second: 10)
    assert length(Enum.uniq(Enum.map(plan, &elem(&1, 1)))) > 150
    assert Spread.duration(plan) >= 19_000
  end

  test "no peers, no plan; a repeat is told once" do
    assert [] = Spread.schedule([])
    assert [{"a", _}] = Spread.schedule(["a", "a"])
    assert 0 = Spread.duration([])
  end
end
