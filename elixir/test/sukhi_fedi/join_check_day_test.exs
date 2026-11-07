# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.JoinApplications.CheckDayTest do
  use ExUnit.Case, async: false

  alias SukhiFedi.JoinApplications.{CheckDay, Mail}

  setup do
    previous = Application.get_env(:sukhi_fedi, :join)
    on_exit(fn -> Application.put_env(:sukhi_fedi, :join, previous || []) end)
    :ok
  end

  defp configure(opts), do: Application.put_env(:sukhi_fedi, :join, opts)

  # 2026-11-02 is a Monday. 03:00 UTC is noon in the +9 day line.
  defp at(date, hour \\ 3), do: DateTime.new!(Date.from_iso8601!(date), Time.new!(hour, 0, 0))

  test "the first allowed weekday after today" do
    configure(check_days: [1, 4], utc_offset_hours: 9)

    assert %{date: ~D[2026-11-05], days_after: 3, weekday: 4} = CheckDay.next(at("2026-11-02"))
    # On the day itself it is the *next* one, not today.
    assert %{date: ~D[2026-11-09], days_after: 4, weekday: 1} = CheckDay.next(at("2026-11-05"))
  end

  test "no weekday set: tomorrow" do
    configure(check_days: [], utc_offset_hours: 9)
    assert %{date: ~D[2026-11-03], days_after: 1} = CheckDay.next(at("2026-11-02"))
  end

  test "a single allowed day is never more than a week away" do
    configure(check_days: [4], utc_offset_hours: 9)
    assert %{days_after: 7, weekday: 4} = CheckDay.next(at("2026-11-05"))
  end

  test "the day line follows the offset" do
    # 20:00 UTC on Monday is already Tuesday at +9.
    configure(check_days: [], utc_offset_hours: 9)
    assert %{date: ~D[2026-11-04]} = CheckDay.next(at("2026-11-02", 20))

    configure(check_days: [], utc_offset_hours: 0)
    assert %{date: ~D[2026-11-03]} = CheckDay.next(at("2026-11-02", 20))
  end

  test "the greeter is what is configured" do
    configure(greeter: "くろ")
    assert CheckDay.greeter() == "くろ"

    configure([])
    assert CheckDay.greeter() == nil
  end

  test "weekday names in each language" do
    assert Mail.weekday_name("ja", 4) == "木曜日"
    assert Mail.weekday_name("ko", 4) == "목요일"
    assert Mail.weekday_name("en", 4) == "Thursday"
    assert Mail.weekday_name(nil, 1) == "月曜日"
  end
end
