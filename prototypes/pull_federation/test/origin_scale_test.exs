# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule OriginScaleTest do
  use ExUnit.Case, async: true

  alias PullFederation.{Calendar, Etag, Origin, Snapshot}

  defp post(o, actor, i),
    do:
      elem(
        Origin.publish(o, actor, %{id: "#{actor}-#{i}", type: :create, visibility: :public}),
        0
      )

  test "the first appointment spacing follows the slot count, not a fixed 50 ms" do
    assert Calendar.new(slots: 64).slot_ms <= 3
    assert Calendar.new(slots: 8).slot_ms == 16
    assert Calendar.new(slots: 8, slot_ms: 7).slot_ms == 7
  end

  test "booking an appointment is counted" do
    o = Origin.new(max_streams: 1) |> Origin.follow("b", "x") |> Origin.follow("c", "x")
    {o, {:ok, _, _}} = Origin.request_stream(o, "b", %{}, 0)
    assert o.calendar.booked == 0
    {o, {:error, {:retry_at, _}}} = Origin.request_stream(o, "c", %{}, 1)
    assert o.calendar.booked == 1
  end

  test "the follow index and announced/2 list only what the domain follows" do
    o =
      Origin.new()
      |> Origin.follow("b", "x")
      |> Origin.follow("c", "y")
      |> post("x", 1)
      |> post("y", 1)

    assert Origin.announced(o, "b") |> Map.keys() == ["x"]
    assert Origin.announced(o, "c") |> Map.keys() == ["y"]
    assert Origin.announced(o, "nobody") == %{}
  end

  test "a notification carries only the keys that changed" do
    o =
      Enum.reduce(1..50, Origin.new(), fn a, o -> Origin.follow(o, "b", "u#{a}") end)
      |> post("u1", 1)

    {_, [{"b", note}]} = Origin.due_notifications(o, 10_000)
    assert Map.keys(note) == ["u1"]
  end

  test "bucket_doc lists the actors of its bucket and no others" do
    o =
      Enum.reduce(1..200, Origin.new(), fn a, o ->
        o |> Origin.follow("b", "u#{a}") |> post("u#{a}", 1)
      end)

    for bucket <- ["u1", "u2", "u77"] |> Enum.map(&Snapshot.bucket/1) |> Enum.uniq() do
      expected =
        for a <- 1..200, Snapshot.bucket("u#{a}") == bucket, into: %{} do
          {Snapshot.hash("u#{a}"), Etag.ordered(1)}
        end

      assert Origin.bucket_doc(o, bucket).entries == expected
    end
  end

  describe "log retention (log_max)" do
    setup do
      o = Origin.new(log_max: 5) |> Origin.follow("b", "x")
      {:ok, o: Enum.reduce(1..30, o, &post(&2, "x", &1))}
    end

    test "the log stays bounded", %{o: o} do
      assert o.log_len["x"] <= 10
      assert length(o.log["x"]) <= 10
    end

    test "a cursor inside the retained range gets exactly what it lacks", %{o: o} do
      {_, {:ok, events, _}} = Origin.request_stream(o, "b", %{"x" => Etag.ordered(28)}, 0)
      assert Enum.map(events, & &1.seq) == [29, 30]
    end

    test "a cursor older than the retained range gets a resync, not a silent gap", %{o: o} do
      {o2, {:ok, events, _}} = Origin.request_stream(o, "b", %{"x" => Etag.ordered(3)}, 0)
      assert o2.resyncs == o.resyncs + 1
      assert hd(events).seq > 4 and List.last(events).seq == 30
    end

    test "the very first pull gets whatever is retained", %{o: o} do
      {_, {:ok, events, _}} = Origin.request_stream(o, "b", %{}, 0)
      assert List.last(events).seq == 30 and length(events) <= 10
    end
  end
end
