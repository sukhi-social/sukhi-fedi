# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.JoinApplications.CheckDay do
  @moduledoc """
  "When will it be looked at": the next day the person who welcomes
  has said is fine (docs/JOIN.md).

  Pure calendar arithmetic, so the page, the receipt mail and the stored
  `check_on` cannot disagree. The day is the first allowed weekday
  *after* today; with no weekday configured, tomorrow. The calendar
  runs on the instance's own day line (`utc_offset_hours`), because
  "Thursday" is a place's Thursday.

  Settings are read from `config :sukhi_fedi, :join`:

    * `:greeter` — the name shown ("くろ"); `nil` when unset
    * `:check_days` — ISO weekdays (1 = Monday … 7 = Sunday)
    * `:utc_offset_hours` — the day line, default 9
  """

  @type t :: %{date: Date.t(), days_after: pos_integer(), weekday: 1..7}

  @doc "The next check day from `now`."
  @spec next(DateTime.t()) :: t()
  def next(%DateTime{} = now \\ DateTime.utc_now()) do
    today = today(now)
    days = days()

    n = Enum.find(1..7, 1, fn n -> Date.day_of_week(Date.add(today, n)) in days end)
    date = Date.add(today, n)

    %{date: date, days_after: n, weekday: Date.day_of_week(date)}
  end

  @doc "The greeter's name, or `nil` when none is set."
  @spec greeter() :: String.t() | nil
  def greeter, do: conf(:greeter, nil)

  @doc "The instance's today."
  @spec today(DateTime.t()) :: Date.t()
  def today(%DateTime{} = now) do
    now |> DateTime.add(conf(:utc_offset_hours, 9) * 3600, :second) |> DateTime.to_date()
  end

  defp days do
    case conf(:check_days, []) do
      [_ | _] = ds -> Enum.filter(ds, &(&1 in 1..7))
      _ -> [1, 2, 3, 4, 5, 6, 7]
    end
  end

  defp conf(key, default) do
    :sukhi_fedi |> Application.get_env(:join, []) |> Keyword.get(key, default)
  end
end
