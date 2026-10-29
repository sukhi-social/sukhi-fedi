# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Eval do
  @moduledoc """
  Evaluates a planned `Ecto.Query` expression against rows in memory.

  This is the *only* place a `where`, `on`, `order_by` or `select` gets its
  meaning for the Datalevin store. The engine may first narrow the rows it
  fetches (see `Query`), but never decides a row is in or out on its own: the
  expression is always evaluated here, on the row, so a pre-filter that is
  merely approximate cannot change an answer.

  SQL's three-valued logic is kept where it matters: comparing with `nil` is
  not true (and not false), so it filters a row out; `is_nil/1` is the way to
  ask about it.

  `env` is `%{rows: tuple_of_row_maps, params: list, group: [env] | nil}`.
  A row is a map keyed by column atoms, or `nil` for the unmatched side of a
  `left_join`.
  """

  defmodule Unsupported do
    defexception [:message]
  end

  @aggregates [:count, :sum, :avg, :min, :max]

  @doc "Evaluate `expr` in `env`."
  @spec eval(term(), map()) :: term()
  # ---- values --------------------------------------------------------------
  def eval({{:., _, [{:&, _, [ix]}, field]}, _, []}, %{rows: rows}) do
    case elem(rows, ix) do
      nil -> nil
      row -> Map.get(row, field)
    end
  end

  def eval({:^, _, [ix]}, %{params: params}), do: Enum.at(params, ix)
  def eval({:^, _, [ix, len]}, %{params: params}), do: Enum.slice(params, ix, len)
  def eval(%Ecto.Query.Tagged{value: v}, env), do: eval(v, env)
  def eval({:type, _, [e, _type]}, env), do: eval(e, env)
  def eval({:literal, _, [v]}, _env), do: v
  def eval({:splice, _, [e]}, env), do: eval(e, env)
  def eval(l, env) when is_list(l), do: Enum.map(l, &eval(&1, env))
  def eval(v, _env) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  def eval({:%{}, _, kvs}, env), do: Map.new(kvs, fn {k, v} -> {k, eval(v, env)} end)

  # ---- logic ---------------------------------------------------------------
  def eval({:and, _, [a, b]}, env) do
    case eval(a, env) do
      x when x in [false, nil] -> if x == false, do: false, else: and_null(eval(b, env))
      _ -> eval(b, env)
    end
  end

  def eval({:or, _, [a, b]}, env) do
    case eval(a, env) do
      true -> true
      x -> if x == nil, do: or_null(eval(b, env)), else: eval(b, env)
    end
  end

  def eval({:not, _, [a]}, env) do
    case eval(a, env) do
      nil -> nil
      v -> not v
    end
  end

  def eval({:is_nil, _, [a]}, env), do: is_nil(eval(a, env))

  # ---- comparison ----------------------------------------------------------
  def eval({op, _, [a, b]}, env) when op in [:==, :!=, :<, :>, :<=, :>=] do
    compare(op, eval(a, env), eval(b, env))
  end

  def eval({:in, _, [a, b]}, env) do
    case {eval(a, env), eval(b, env)} do
      {nil, _} -> nil
      {_, nil} -> nil
      {v, list} when is_list(list) -> Enum.any?(list, &(&1 == v))
    end
  end

  def eval({:like, _, [a, b]}, env), do: like(eval(a, env), eval(b, env), false)
  def eval({:ilike, _, [a, b]}, env), do: like(eval(a, env), eval(b, env), true)

  # ---- arithmetic ----------------------------------------------------------
  def eval({op, _, [a, b]}, env) when op in [:+, :-, :*, :/] do
    case {eval(a, env), eval(b, env)} do
      {nil, _} -> nil
      {_, nil} -> nil
      {x, y} -> arith(op, x, y)
    end
  end

  def eval({:coalesce, _, args}, env), do: Enum.find_value(args, fn a -> eval(a, env) end)
  def eval({:fragment, _, parts}, env), do: fragment(parts, env)

  # now ± interval, in the stored unit (microseconds since the epoch).
  def eval({:ago, _, [n, unit]}, env), do: System.os_time(:microsecond) - interval(eval(n, env), unit)

  def eval({:from_now, _, [n, unit]}, env),
    do: System.os_time(:microsecond) + interval(eval(n, env), unit)

  def eval({:datetime_add, _, [base, n, unit]}, env) do
    case eval(base, env) do
      nil -> nil
      us -> us + interval(eval(n, env), unit)
    end
  end

  def eval({:date_add, _, [base, n, unit]}, env) do
    case eval(base, env) do
      nil -> nil
      days -> days + div(interval(eval(n, env), unit), 86_400_000_000)
    end
  end

  def eval({:json_extract_path, _, [e, path]}, env), do: json_path(eval(e, env), path)

  # ---- aggregates ----------------------------------------------------------
  def eval({agg, _, args}, %{group: group} = env) when agg in @aggregates and is_list(group),
    do: aggregate(agg, args, group, env)

  def eval({agg, _, _}, _env) when agg in @aggregates,
    do: raise(Unsupported, "aggregate #{agg} outside of a select")

  def eval({:selected_as, _, [e, _]}, env), do: eval(e, env)

  def eval(other, _env), do: raise(Unsupported, "expression not supported by the Datalevin store: #{inspect(other)}")

  # ---------------------------------------------------------------------------

  defp and_null(false), do: false
  defp and_null(_), do: nil
  defp or_null(true), do: true
  defp or_null(_), do: nil

  defp compare(_op, nil, _), do: nil
  defp compare(_op, _, nil), do: nil
  defp compare(:==, a, b), do: equal?(a, b)
  defp compare(:!=, a, b), do: not equal?(a, b)
  defp compare(:<, a, b), do: a < b
  defp compare(:>, a, b), do: a > b
  defp compare(:<=, a, b), do: a <= b
  defp compare(:>=, a, b), do: a >= b

  # 1 == 1.0 in SQL.
  defp equal?(a, b) when is_number(a) and is_number(b), do: a == b
  defp equal?(a, b), do: a === b

  defp arith(:+, x, y), do: x + y
  defp arith(:-, x, y), do: x - y
  defp arith(:*, x, y), do: x * y
  defp arith(:/, x, y), do: x / y

  defp like(nil, _, _), do: nil
  defp like(_, nil, _), do: nil

  defp like(value, pattern, ci?) when is_binary(value) and is_binary(pattern) do
    {value, pattern} = if ci?, do: {String.downcase(value), String.downcase(pattern)}, else: {value, pattern}
    Regex.match?(like_regex(pattern), value)
  end

  # Patterns come from parameters, so they are compiled per call rather than
  # cached: a cache keyed by user input never stops growing.
  defp like_regex(pattern) do
    body =
      pattern
      |> String.graphemes()
      |> Enum.map_join(fn
        "%" -> ".*"
        "_" -> "."
        c -> Regex.escape(c)
      end)

    Regex.compile!("\\A" <> body <> "\\z", "us")
  end

  # -- fragments: the handful of SQL snippets the code base writes ---------------
  #
  # Matched on the template with each expression replaced by `?`. Anything
  # else raises rather than guess, and shows up in the coverage run.
  defp fragment(parts, env) do
    template = Enum.map_join(parts, fn {:raw, s} -> s; {:expr, _} -> "?" end)
    args = for {:expr, e} <- parts, do: eval(e, env)
    fragment_fun(template, args, parts)
  end

  defp fragment_fun("lower(?)", [v], _), do: if(is_binary(v), do: String.downcase(v), else: v)
  defp fragment_fun("length(?)", [v], _), do: if(is_binary(v), do: String.length(v), else: nil)
  defp fragment_fun("? LIKE ?", [a, b], _), do: like(a, b, false)
  defp fragment_fun("now()", [], _), do: System.os_time(:microsecond)
  defp fragment_fun("CAST(?->>'" <> rest, [v], _), do: json_text(v, rest |> String.split("'") |> hd())
  defp fragment_fun("?->>'" <> rest, [v], _), do: json_text(v, rest |> String.split("'") |> hd())

  defp fragment_fun("EXISTS (SELECT 1 FROM " <> _ = template, [v], _) do
    case Regex.run(~r/^EXISTS \(SELECT 1 FROM (\w+) \w+ WHERE \w+\.(\w+) = \?\)$/, template) do
      [_, table, column] -> SukhiFedi.Datalevin.Query.exists_row?(table, column, v)
      _ -> raise Unsupported, "fragment not supported by the Datalevin store: #{inspect(template)}"
    end
  end

  defp fragment_fun(template, _args, _parts),
    do: raise(Unsupported, "fragment not supported by the Datalevin store: #{inspect(template)}")

  defp json_text(nil, _), do: nil

  defp json_text(v, key) do
    case if(is_binary(v), do: JSON.decode!(v), else: v) do
      %{^key => nil} -> nil
      %{^key => x} when is_binary(x) -> x
      %{^key => x} -> to_string(x)
      _ -> nil
    end
  end

  defp json_path(nil, _), do: nil

  defp json_path(v, path) do
    root = if is_binary(v), do: JSON.decode!(v), else: v
    get_in(root, path)
  end

  defp interval(n, unit) when is_number(n) do
    n * case unit do
      "microsecond" -> 1
      "millisecond" -> 1_000
      "second" -> 1_000_000
      "minute" -> 60_000_000
      "hour" -> 3_600_000_000
      "day" -> 86_400_000_000
      "week" -> 7 * 86_400_000_000
      "month" -> 30 * 86_400_000_000
      "year" -> 365 * 86_400_000_000
    end
  end

  defp aggregate(:count, [], group, _env), do: length(group)

  defp aggregate(:count, [expr | rest], group, _env) do
    values = group |> Enum.map(&eval(expr, &1)) |> Enum.reject(&is_nil/1)
    values = if :distinct in rest, do: Enum.uniq(values), else: values
    length(values)
  end

  defp aggregate(agg, [expr | rest], group, _env) do
    values = group |> Enum.map(&eval(expr, &1)) |> Enum.reject(&is_nil/1)
    values = if :distinct in rest, do: Enum.uniq(values), else: values

    case {agg, values} do
      {_, []} -> nil
      {:sum, vs} -> Enum.sum(vs)
      {:avg, vs} -> Enum.sum(vs) / length(vs)
      {:min, vs} -> Enum.min(vs)
      {:max, vs} -> Enum.max(vs)
    end
  end

  @doc "Does the expression contain an aggregate call?"
  @spec aggregate?(term()) :: boolean()
  def aggregate?({agg, _, _}) when agg in @aggregates, do: true
  def aggregate?({_, _, args}) when is_list(args), do: Enum.any?(args, &aggregate?/1)
  def aggregate?(l) when is_list(l), do: Enum.any?(l, &aggregate?/1)
  def aggregate?({_, v}), do: aggregate?(v)
  def aggregate?(_), do: false
end
