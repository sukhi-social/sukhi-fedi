# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Types do
  @moduledoc """
  How Ecto values are kept in Datalevin, and back.

  The rule: what is stored is what a query compares, so ordering and
  equality in the engine mean the same as in SQL.

      timestamps   microseconds since the Unix epoch (a long)
      dates        days of the proleptic Gregorian calendar (a long)
      maps, lists  JSON text (a string); never compared inside the engine
      binaries     Base64 text (a string)
      decimals     text

  `dumpers/2` and `loaders/2` are the adapter's answer to Ecto: they run on
  every value that crosses in or out, including query parameters, so a
  `where created_at > ^cutoff` reaches the evaluator already as microseconds.
  """

  @doc "Ecto `dumpers/2`."
  def dumpers(primitive, type)

  def dumpers(p, type) when p in [:utc_datetime, :utc_datetime_usec, :naive_datetime, :naive_datetime_usec],
    do: [type, &micros/1]

  def dumpers(:date, type), do: [type, &days/1]
  def dumpers(:time, type), do: [type, &time_micros/1]
  def dumpers(:time_usec, type), do: [type, &time_micros/1]
  def dumpers(:decimal, type), do: [type, &decimal_text/1]
  def dumpers(:binary, type), do: [type, &base64/1]
  def dumpers(:binary_id, type), do: [type, Ecto.UUID]
  def dumpers(:map, type), do: [type, &json/1]
  def dumpers({:map, _}, type), do: [&Ecto.Type.embedded_dump(type, &1, :json), &json/1]
  def dumpers({:array, _}, type), do: [type, &json/1]
  def dumpers(_, type), do: [type]

  @doc "Ecto `loaders/2`."
  def loaders(primitive, type)

  def loaders(p, type) when p in [:utc_datetime, :utc_datetime_usec],
    do: [&from_micros(&1, p), type]

  def loaders(p, type) when p in [:naive_datetime, :naive_datetime_usec],
    do: [&from_micros_naive(&1, p), type]

  def loaders(:date, type), do: [&from_days/1, type]
  def loaders(p, type) when p in [:time, :time_usec], do: [&from_time_micros/1, type]
  def loaders(:decimal, type), do: [&decimal_load/1, type]
  def loaders(:binary, type), do: [&unbase64/1, type]
  def loaders(:binary_id, type), do: [Ecto.UUID, type]
  def loaders(:map, type), do: [&unjson/1, type]
  def loaders({:map, _}, type), do: [&unjson/1, &Ecto.Type.embedded_load(type, &1, :json)]
  def loaders({:array, _}, type), do: [&unjson/1, type]
  def loaders(_, type), do: [type]

  # -- timestamps -----------------------------------------------------------

  def micros(%DateTime{} = dt), do: {:ok, DateTime.to_unix(dt, :microsecond)}

  def micros(%NaiveDateTime{} = nd),
    do: {:ok, nd |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)}

  def micros(_), do: :error

  defp from_micros(nil, _), do: {:ok, nil}

  defp from_micros(us, p) when is_integer(us) do
    dt = DateTime.from_unix!(us, :microsecond)
    {:ok, if(p == :utc_datetime, do: %{dt | microsecond: {0, 0}}, else: dt)}
  end

  defp from_micros_naive(nil, _), do: {:ok, nil}

  defp from_micros_naive(us, p) when is_integer(us) do
    nd = us |> DateTime.from_unix!(:microsecond) |> DateTime.to_naive()
    {:ok, if(p == :naive_datetime, do: %{nd | microsecond: {0, 0}}, else: nd)}
  end

  # -- dates ----------------------------------------------------------------

  defp days(%Date{} = d), do: {:ok, Date.to_gregorian_days(d)}
  defp days(_), do: :error
  defp from_days(nil), do: {:ok, nil}
  defp from_days(n) when is_integer(n), do: {:ok, Date.from_gregorian_days(n)}

  defp time_micros(%Time{} = t), do: {:ok, div(Time.diff(t, ~T[00:00:00.000000], :microsecond), 1)}
  defp time_micros(_), do: :error
  defp from_time_micros(nil), do: {:ok, nil}
  defp from_time_micros(n) when is_integer(n), do: {:ok, Time.add(~T[00:00:00.000000], n, :microsecond)}

  # -- the rest ---------------------------------------------------------------

  defp decimal_text(%Decimal{} = d), do: {:ok, Decimal.to_string(d)}
  defp decimal_text(_), do: :error
  defp decimal_load(nil), do: {:ok, nil}
  defp decimal_load(s) when is_binary(s), do: {:ok, Decimal.new(s)}

  defp base64(b) when is_binary(b), do: {:ok, Base.encode64(b)}
  defp base64(_), do: :error
  defp unbase64(nil), do: {:ok, nil}
  defp unbase64(s) when is_binary(s), do: Base.decode64(s)

  defp json(v), do: {:ok, v |> JSON.encode!()}
  defp unjson(nil), do: {:ok, nil}
  defp unjson(s) when is_binary(s), do: {:ok, JSON.decode!(s)}

  # -- column defaults ----------------------------------------------------------

  @doc """
  A Postgres `column_default` as the value to store, or `:none` when it is
  something the store does not mint (a sequence is handled by the id counter;
  `snowflake_id()` by `SukhiFedi.Datalevin.Ids`).
  """
  @spec default(String.t()) :: {:value, term()} | :now | :sequence | :snowflake | :none
  def default(default) do
    cond do
      Regex.match?(~r/^nextval\(/, default) -> :sequence
      default == "snowflake_id()" -> :snowflake
      default in ["now()", "CURRENT_TIMESTAMP", "timezone('UTC'::text, now())"] -> :now
      default == "true" -> {:value, true}
      default == "false" -> {:value, false}
      Regex.match?(~r/^-?\d+$/, default) -> {:value, String.to_integer(default)}
      Regex.match?(~r/^-?\d+\.\d+$/, default) -> {:value, String.to_float(default)}
      String.starts_with?(default, "ARRAY[]::") -> {:value, "[]"}
      m = Regex.run(~r/^'(.*)'::[a-z_ ]+(\[\])?$/s, default) -> {:value, String.replace(Enum.at(m, 1), "''", "'")}
      true -> :none
    end
  end
end
