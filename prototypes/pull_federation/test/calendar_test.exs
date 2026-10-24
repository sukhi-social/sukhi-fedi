# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule CalendarTest do
  use ExUnit.Case, async: true

  alias PullFederation.{Calendar, Origin}

  @a "https://a.example/users/alice"

  defp cal(opts \\ []),
    do: Calendar.new(Keyword.merge([slot_ms: 100, grace_ms: 500, horizon_ms: 1_000], opts))

  describe "Calendar" do
    test "appointments are spaced one slot apart, starting a slot from now" do
      {c, {:ok, 100}} = Calendar.book(cal(), "a", 0)
      {c, {:ok, 200}} = Calendar.book(c, "b", 0)
      {_, {:ok, 300}} = Calendar.book(c, "c", 0)
    end

    test "an idle book starts from now, not from a stale pointer" do
      {c, {:ok, 100}} = Calendar.book(cal(), "a", 0)
      assert {_, {:ok, 100}} = Calendar.book(c, "b", 10_000)
    end

    test "claim: early, due, due late within grace, expired" do
      {c, {:ok, 100}} = Calendar.book(cal(), "a", 0)
      assert Calendar.claim(c, "a", 40) == {:early, 60}
      assert Calendar.claim(c, "a", 100) == :due
      assert Calendar.claim(c, "a", 600) == :due
      assert Calendar.claim(c, "a", 601) == :expired
      assert Calendar.claim(c, "nobody", 0) == :none
    end

    test "nothing is promised beyond the horizon" do
      c = Enum.reduce(1..10, cal(), fn i, c -> elem(Calendar.book(c, "d#{i}", 0), 0) end)
      assert Calendar.size(c) == 10
      assert {^c, {:shed, 1_000}} = Calendar.book(c, "late", 0)
    end

    test "postpone keeps the promise, one slot from now, and leaves the book alone" do
      {c, {:ok, 100}} = Calendar.book(cal(), "a", 0)
      {c2, 100} = Calendar.postpone(c, "a", 150)
      assert Calendar.claim(c2, "a", 200) == {:early, 50}
      assert c2.next_slot == c.next_slot
    end

    test "the slot follows the observed stream time" do
      c = cal(slots: 8, slot_ms: 50, utilization: 1.0)
      c = Calendar.observe_stream(c, 400)
      assert c.slot_ms == 50
      c = Enum.reduce(1..20, c, fn _, c -> Calendar.observe_stream(c, 1_600) end)
      assert c.slot_ms in 190..200

      # with the default headroom the book fills only 80% of capacity
      c = Calendar.observe_stream(cal(slots: 8), 400)
      assert c.slot_ms == 63
    end

    test "sweep drops lapsed promises and keeps live ones" do
      {c, _} = Calendar.book(cal(), "a", 0)
      {c, _} = Calendar.book(c, "b", 0)
      assert Calendar.size(Calendar.sweep(c, 650)) == 1
      assert Calendar.size(Calendar.sweep(c, 701)) == 0
    end

    test "pending? and claimed?" do
      {c, _} = Calendar.book(cal(), "a", 0)
      assert Calendar.pending?(c, 0)
      refute Calendar.pending?(c, 500)
      assert Calendar.claimed?(c, "a", 50)
      assert Calendar.claimed?(c, "a", 300)
      refute Calendar.claimed?(c, "a", 700)
      refute Calendar.claimed?(c, "b", 0)
    end
  end

  describe "Origin with a calendar" do
    defp origin(opts \\ []) do
      o =
        Origin.new(
          Keyword.merge(
            [max_streams: 1, calendar: [slot_ms: 50, grace_ms: 100, horizon_ms: 200]],
            opts
          )
        )

      Enum.reduce(
        ["b.example", "c.example", "d.example", "e.example", "f.example", "g.example"],
        o,
        fn d, acc ->
          Origin.follow(acc, d, @a)
        end
      )
    end

    defp note(id), do: %{type: :create, id: id, visibility: :public}

    test "a full house hands out appointments; coming early costs nothing" do
      {:ok, o, _, _} = Origin.open_stream(origin(), "b.example", %{}, 0)
      {o, {:error, {:retry_at, 50}}} = Origin.request_stream(o, "c.example", %{}, 0)
      {o, {:error, {:retry_at, 30}}} = Origin.request_stream(o, "c.example", %{}, 20)
      assert o.calendar.next_slot == 100

      o = Origin.close_stream(o)
      assert {_, {:ok, _, _}} = Origin.request_stream(o, "c.example", %{}, 50)
    end

    test "nobody walks in ahead of a promise" do
      {:ok, o, _, _} = Origin.open_stream(origin(), "b.example", %{}, 0)
      {o, {:error, {:retry_at, 50}}} = Origin.request_stream(o, "c.example", %{}, 0)
      o = Origin.close_stream(o)

      # a slot is free, but c holds 50: d must book, not take it
      assert {o, {:error, {:retry_at, 90}}} = Origin.request_stream(o, "d.example", %{}, 10)
      assert o.active_streams == 0
    end

    test "a holder who finds the house full keeps its promise, one slot on" do
      {:ok, o, _, _} = Origin.open_stream(origin(), "b.example", %{}, 0)
      {o, {:error, {:retry_at, 50}}} = Origin.request_stream(o, "c.example", %{}, 0)
      assert {o, {:error, {:retry_at, 50}}} = Origin.request_stream(o, "c.example", %{}, 50)

      assert Origin.close_stream(o)
             |> Origin.request_stream("c.example", %{}, 100)
             |> elem(1)
             |> elem(0) == :ok
    end

    test "a promise let lapse is forfeited; the domain is a fresh arrival" do
      {:ok, o, _, _} = Origin.open_stream(origin(), "b.example", %{}, 0)
      {o, {:error, {:retry_at, 50}}} = Origin.request_stream(o, "c.example", %{}, 0)
      # grace is 100 ms: at 151 the promise (50) is gone
      assert {_, {:error, {:retry_at, ms}}} = Origin.request_stream(o, "c.example", %{}, 151)
      assert ms > 0
      assert {:ok, _, _, _} = origin() |> Origin.open_stream("c.example", %{}, 151)
    end

    test "the horizon sheds: nothing is promised, the domain is told to try later" do
      {:ok, o, _, _} = Origin.open_stream(origin(), "b.example", %{}, 0)
      {o, {:error, {:retry_at, 50}}} = Origin.request_stream(o, "c.example", %{}, 0)
      {o, {:error, {:retry_at, 100}}} = Origin.request_stream(o, "d.example", %{}, 0)
      {o, {:error, {:retry_at, 150}}} = Origin.request_stream(o, "e.example", %{}, 0)
      {o, {:error, {:retry_at, 200}}} = Origin.request_stream(o, "f.example", %{}, 0)
      {o, {:error, {:busy, 200}}} = Origin.request_stream(o, "g.example", %{}, 0)
      assert Calendar.size(o.calendar) == 4
    end

    test "a domain holding a promise is not nagged with notifications" do
      {:ok, o, _, _} = Origin.open_stream(origin(), "b.example", %{}, 0)
      {o, {:error, {:retry_at, 50}}} = Origin.request_stream(o, "c.example", %{}, 0)
      {o, _} = Origin.publish(o, @a, note("1"))
      {_, due} = Origin.due_notifications(o, 10_000 - 10_000 + 60)
      domains = for {d, _} <- due, do: d
      refute "c.example" in domains
      assert "d.example" in domains
    end

    test "a pull makes the notification behind it redundant" do
      o = origin(max_streams: 4)
      {o, _} = Origin.publish(o, @a, note("1"))
      assert Map.has_key?(o.dirty, "b.example")
      {:ok, o, events, _} = Origin.open_stream(o, "b.example", %{}, 0)
      assert length(events) == 1
      refute Map.has_key?(o.dirty, "b.example")
      {_, due} = Origin.due_notifications(o, 10_000)
      refute "b.example" in Enum.map(due, &elem(&1, 0))
    end

    test "closing a stream feeds its real duration to the calendar" do
      o = origin(max_streams: 2, calendar: [slots: 2, slot_ms: 50])
      {:ok, o, _, _} = Origin.open_stream(o, "b.example", %{}, 0)
      o = Origin.close_stream(o, "b.example", 600)
      assert o.calendar.slot_ms == 375
    end
  end

  describe "invariants under random traffic" do
    test "slots, book size and the pointer stay in bounds over 5,000 random steps" do
      :rand.seed(:exsss, {3, 1, 4})
      domains = for i <- 1..40, do: "d#{i}.example"

      o0 =
        Enum.reduce(
          domains,
          Origin.new(max_streams: 3, calendar: [slot_ms: 40, grace_ms: 120, horizon_ms: 2_000]),
          fn d, acc ->
            Origin.follow(acc, d, @a)
          end
        )

      {_o, _now, open} =
        Enum.reduce(1..5_000, {o0, 0, []}, fn _, {o, now, open} ->
          now = now + :rand.uniform(30)
          d = Enum.random(domains)
          before = o.calendar.next_slot

          {o, open} =
            case :rand.uniform(3) do
              1 ->
                case open do
                  [] -> {o, open}
                  [x | rest] -> {Origin.close_stream(o, x, now), rest}
                end

              _ ->
                case Origin.request_stream(o, d, %{}, now) do
                  {o, {:ok, _, _}} -> {o, [d | open]}
                  {o, {:error, _}} -> {o, open}
                end
            end

          assert o.active_streams <= 3
          assert o.active_streams == length(open)
          assert Calendar.size(o.calendar) <= length(domains)
          assert o.calendar.next_slot >= before
          {o, now, open}
        end)

      assert length(open) <= 3
    end
  end
end
