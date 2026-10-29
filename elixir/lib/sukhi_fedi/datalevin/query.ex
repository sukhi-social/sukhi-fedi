# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Query do
  @moduledoc """
  Runs a planned `Ecto.Query` against Datalevin.

  A query that Postgres answers with one many-way join is answered here as a
  few small reads and an in-memory join:

    1. the root table, narrowed by every `where` condition that is a simple
       comparison on its columns;
    2. for each `join`, one read of the joined table, narrowed by the keys the
       rows so far carry (`id IN (…)`) and by the conditions on its columns —
       all of a query's reads for one step go out in one pipelined batch;
    3. the join, the full `where`, grouping, ordering, `limit` and `select`
       evaluated in memory by `Eval`.

  Step 3 is the only authority on what a row means; step 1 and 2's narrowing
  is a pre-filter (see `Engine`). Anything this module cannot do raises
  `Eval.Unsupported`, naming it — it never answers approximately.
  """

  alias SukhiFedi.Datalevin.{Client, Datalog, Engine, Eval, Writer}
  alias Eval.Unsupported

  @doc "Rows of `select.fields` values, in order."
  @spec all(Ecto.Query.t(), list()) :: [[term()]]
  def all(%Ecto.Query{} = q, params) do
    scoped(fn ->
      check!(q)
      {tuples, paged?} = tuples(q, params)
      envs = shape(tuples, q, params, paged?)
      rows = Enum.map(envs, fn env -> Enum.map(q.select.fields, &Eval.eval(&1, env)) end)
      Enum.reduce(q.combinations, rows, fn {kind, other}, acc -> combine(kind, acc, all(other, params)) end)
    end)
  end

  defp combine(:union, a, b), do: Enum.uniq(a ++ b)
  defp combine(:union_all, a, b), do: a ++ b
  defp combine(:except, a, b), do: a |> Enum.uniq() |> Enum.reject(&(&1 in b))
  defp combine(:except_all, a, b), do: a -- b
  defp combine(:intersect, a, b), do: a |> Enum.uniq() |> Enum.filter(&(&1 in b))
  defp combine(:intersect_all, a, b), do: a -- (a -- b)

  # A subquery inside a `where` is evaluated once per statement, not once per
  # row: the outermost statement opens a cache that its subqueries share.
  defp scoped(fun) do
    if Process.get(:dtlv_sq_cache) do
      fun.()
    else
      Process.put(:dtlv_sq_cache, %{})

      try do
        fun.()
      after
        Process.delete(:dtlv_sq_cache)
      end
    end
  end

  @doc "Apply `updates` to the rows meeting the query; `{count, rows | nil}`."
  @spec update_all(Ecto.Query.t(), list()) :: {non_neg_integer(), [[term()]] | nil}
  def update_all(%Ecto.Query{} = q, params) do
    check!(q)
    if q.joins != [], do: raise(Unsupported, "update_all with joins")
    table = table!(q, 0)

    scoped(fn ->
      Writer.transaction_if_needed(fn ->
        found = matching(q, params, table)

        rows =
          for {eid, old} <- found do
            env = %{rows: {old}, params: params, group: nil}
            new = apply_updates(q.updates, old, env)

            case Writer.replace(table, eid, old, new) do
              :ok ->
                new

              {:invalid, c} ->
                raise Ecto.ConstraintError,
                  type: :unique,
                  constraint: elem(hd(c), 1),
                  changeset: nil
            end
          end

        returned(q, params, rows)
      end)
    end)
  end

  @doc "Delete the rows meeting the query; `{count, rows | nil}`."
  @spec delete_all(Ecto.Query.t(), list()) :: {non_neg_integer(), [[term()]] | nil}
  def delete_all(%Ecto.Query{} = q, params) do
    check!(q)
    if q.joins != [], do: raise(Unsupported, "delete_all with joins")
    table = table!(q, 0)

    scoped(fn ->
      Writer.transaction_if_needed(fn ->
        found = matching(q, params, table)

        for {eid, old} <- found do
          case Writer.delete_row(table, eid, old) do
            :ok ->
              :ok

            {:invalid, c} ->
              raise Ecto.ConstraintError,
                type: :foreign_key,
                constraint: elem(hd(c), 1),
                changeset: nil
          end
        end

        returned(q, params, Enum.map(found, &elem(&1, 1)))
      end)
    end)
  end

  @doc "Is there a row in `table` whose `column` equals `value`? (fragment `EXISTS` helper)"
  @spec exists_row?(String.t(), String.t(), term()) :: boolean()
  def exists_row?(_table, _column, nil), do: false

  def exists_row?(table, column, value),
    do: Engine.count(table, [{:eq, String.to_atom(column), value}]) > 0

  # ------------------------------------------------------------------ steps

  defp matching(q, params, table) do
    conj = conjuncts(q)
    pds = pushdowns(conj, 0, %{rows: {}, params: params, group: nil}, [])
    where = where_expr(q)

    for {eid, row} <- Engine.fetch(table, pds),
        truthy?(Eval.eval(where, %{rows: {row}, params: params, group: nil})),
        do: {eid, row}
  end

  defp returned(q, params, rows) do
    case q.select do
      nil ->
        {length(rows), nil}

      %{fields: fields} ->
        {length(rows),
         Enum.map(rows, fn r ->
           env = %{rows: {r}, params: params, group: nil}
           Enum.map(fields, &Eval.eval(&1, env))
         end)}
    end
  end

  defp apply_updates(updates, old, env) do
    Enum.reduce(updates, old, fn %{expr: kw}, acc ->
      Enum.reduce(kw, acc, fn
        {:set, sets}, a ->
          Enum.reduce(sets, a, fn {f, e}, aa -> Map.put(aa, f, Eval.eval(e, env)) end)

        {:inc, incs}, a ->
          Enum.reduce(incs, a, fn {f, e}, aa ->
            Map.put(aa, f, (Map.get(aa, f) || 0) + Eval.eval(e, env))
          end)

        {op, _}, _ ->
          raise Unsupported, "update operator #{op}"
      end)
    end)
  end

  # The rows of the whole FROM … JOIN …, as tuples of row maps, after `where`.
  #
  # The leading run of table sources joined `inner`/`cross` is one Datalog
  # query (see `Datalog`); a left join, a subquery or anything after them is
  # joined in memory on top of that. Returns `{tuples, paged?}`: `paged?` says
  # the engine already ordered, offset and limited them.
  defp tuples(q, params) do
    where = where_expr(q)
    conj = conjuncts(q)
    span = datalog_span(q)

    {base, residual, paged?} =
      if span > 0, do: datalog(q, span, params), else: hybrid_root(q, conj, params)

    rest = q.joins |> Enum.with_index(1) |> Enum.drop(max(span - 1, 0))

    tuples =
      rest
      |> Enum.reduce(base, fn {j, ix}, acc -> join(acc, j, ix, conj, params) end)
      |> Enum.filter(fn rows ->
        env = %{rows: rows, params: params, group: nil}
        truthy?(Eval.eval(where, env)) and Enum.all?(residual, &truthy?(Eval.eval(&1, env)))
      end)

    {tuples, paged? and rest == []}
  end

  defp hybrid_root(q, conj, params) do
    base_env = %{rows: {}, params: params, group: nil}

    rows =
      q.sources
      |> elem(0)
      |> fetch_source(pushdowns(conj, 0, base_env, []), params)
      |> Enum.map(fn {_, r} -> {r} end)

    {rows, [], false}
  end

  # How many bindings (root + leading plain joins) the Datalog query covers;
  # 0 when the root is not a table.
  defp datalog_span(q) do
    case elem(q.sources, 0) do
      {t, _, _} when is_binary(t) ->
        1 + (q.joins |> Enum.take_while(&plain_join?/1) |> length())

      _ ->
        0
    end
  end

  defp plain_join?(%{qual: qual, source: {t, _}}) when qual in [:inner, :cross] and is_binary(t), do: true
  defp plain_join?(_), do: false

  defp datalog(q, span, params) do
    tables = for ix <- 0..(span - 1), do: table!(q, ix)
    ons = q.joins |> Enum.take(span - 1) |> Enum.flat_map(&split_and(&1.on.expr))
    wheres = if Enum.all?(q.wheres, &(&1.op == :and)), do: conjuncts(q), else: [where_expr(q)]
    covered = Enum.filter(wheres, fn c -> Enum.all?(bindings(c), &(&1 < span)) end)

    # Order and paging go to the engine only when nothing is left to evaluate
    # in memory afterwards and the query is a plain select.
    plain? =
      span == tuple_size(q.sources) and q.group_bys == [] and q.havings == [] and is_nil(q.distinct) and
        not Enum.any?(q.select.fields, &Eval.aggregate?/1) and
        length(covered) == length(wheres)

    order = if plain? and q.order_bys != [], do: Enum.flat_map(q.order_bys, & &1.expr)
    plan = Datalog.compile(tables, ons ++ covered, params, order: order, limit: q.limit && q.limit.expr, offset: q.offset && q.offset.expr)

    if plan.empty? do
      {[], [], false}
    else
      {rows, ordered?} = run(plan, tables)
      {rows, plan.residual, ordered? and Datalog.paged?(plan) and plain?}
    end
  end

  defp run(plan, tables) do
    n = length(tables)

    edn = Datalog.to_edn(plan)
    if System.get_env("DATALEVIN_TRACE"), do: IO.puts(:stderr, "[datalevin] " <> edn)

    case Client.query(edn) do
      {:ok, rows} ->
        {decode_tuples(rows, tables, n), true}

      {:error, %{"code" => ":result-too-large"}} ->
        {slices(plan, tables, n), false}

      {:error, e} ->
        raise "datalevin query failed: #{inspect(e)}"
    end
  end

  # Too many tuples for one answer: split on the root entity id.
  defp slices(plan, tables, n) do
    plain = %{plan | order: [], order_clauses: [], limit: nil, offset: nil}

    max =
      case Client.query(Datalog.max_edn(plain)) do
        {:ok, m} when is_integer(m) -> m
        _ -> 0
      end

    slice(plain, tables, n, 0, max + 1)
  end

  defp slice(plan, tables, n, lo, hi) do
    extra = " [(>= ?e0 #{lo})] [(< ?e0 #{hi})]"

    case Client.query(Datalog.to_edn(plan, extra)) do
      {:ok, rows} ->
        decode_tuples(rows, tables, n)

      {:error, %{"code" => ":result-too-large"}} when hi - lo > 1 ->
        mid = div(lo + hi, 2)
        slice(plan, tables, n, lo, mid) ++ slice(plan, tables, n, mid, hi)

      {:error, e} ->
        raise "datalevin query failed: #{inspect(e)}"
    end
  end

  defp decode_tuples(rows, tables, n) do
    Enum.map(rows, fn r ->
      r
      |> Enum.take(n)
      |> Enum.zip(tables)
      |> Enum.map(fn {m, t} -> t |> Engine.decode(m) |> elem(1) end)
      |> List.to_tuple()
    end)
  end

  defp bindings({{:., _, [{:&, _, [i]}, _]}, _, []}), do: [i]
  defp bindings({_, _, args}) when is_list(args), do: Enum.flat_map(args, &bindings/1)
  defp bindings(l) when is_list(l), do: Enum.flat_map(l, &bindings/1)
  defp bindings({_, v}), do: bindings(v)
  defp bindings(_), do: []

  defp join(left, j, ix, conj, params) do
    unless j.qual in [:inner, :left, :cross],
      do: raise(Unsupported, "#{j.qual} join (only inner, left and cross)")

    source = join_source!(j)
    on = j.on.expr
    on_conj = split_and(on)
    all_conj = on_conj ++ if(j.qual == :inner, do: conj, else: [])
    static = pushdowns(all_conj, ix, %{rows: {}, params: params, group: nil}, [])

    {equi_col, key_expr} = equi(on_conj, ix) || {nil, nil}

    keys =
      if equi_col do
        left
        |> Enum.map(&Eval.eval(key_expr, %{rows: &1, params: params, group: nil}))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
      end

    right =
      cond do
        equi_col && keys == [] ->
          []

        equi_col ->
          source
          |> fetch_source(static ++ [{:in, equi_col, keys}], params)
          |> Enum.map(&elem(&1, 1))

        true ->
          source |> fetch_source(static, params) |> Enum.map(&elem(&1, 1))
      end

    index = if equi_col, do: Enum.group_by(right, &Map.get(&1, equi_col)), else: nil
    nil_row = nil

    Enum.flat_map(left, fn rows ->
      cands =
        if index do
          case Eval.eval(key_expr, %{rows: rows, params: params, group: nil}) do
            nil -> []
            k -> Map.get(index, k, [])
          end
        else
          right
        end

      matched =
        for r <- cands,
            t = Tuple.insert_at(rows, tuple_size(rows), r),
            truthy?(Eval.eval(on, %{rows: t, params: params, group: nil})),
            do: t

      case {matched, j.qual} do
        {[], :left} -> [Tuple.insert_at(rows, tuple_size(rows), nil_row)]
        {m, _} -> m
      end
    end)
  end

  # `ix.col == <expression over earlier bindings>` among the join's conditions.
  defp equi(conj, ix) do
    Enum.find_value(conj, fn
      {:==, _, [a, b]} -> equi_pair(a, b, ix) || equi_pair(b, a, ix)
      _ -> nil
    end)
  end

  defp equi_pair(a, b, ix) do
    with col when not is_nil(col) <- field_of(a, ix),
         r = refs(b),
         true <- r != [] and Enum.all?(r, &(&1 < ix)) do
      {col, b}
    else
      _ -> nil
    end
  end

  # ------------------------------------------------------- shaping the result

  defp shape(tuples, q, params, paged?) do
    grouped? =
      q.group_bys != [] or q.havings != [] or Enum.any?(q.select.fields, &Eval.aggregate?/1)

    envs =
      if grouped? do
        group(tuples, q, params)
      else
        Enum.map(tuples, &%{rows: &1, params: params, group: nil})
      end

    if paged? do
      envs
    else
      envs |> order(q) |> distinct(q) |> offset_limit(q, params)
    end
  end

  defp group(tuples, q, params) do
    n = tuple_size(q.sources)
    key_exprs = Enum.flat_map(q.group_bys, & &1.expr)

    groups =
      if key_exprs == [] do
        [tuples]
      else
        tuples
        |> Enum.group_by(fn t ->
          Enum.map(key_exprs, &Eval.eval(&1, %{rows: t, params: params, group: nil}))
        end)
        |> Map.values()
      end

    for g <- groups,
        env = %{
          rows: if(g == [], do: Tuple.duplicate(nil, n), else: hd(g)),
          params: params,
          group: Enum.map(g, &%{rows: &1, params: params, group: nil})
        },
        Enum.all?(q.havings, &truthy?(Eval.eval(&1.expr, env))),
        do: env
  end

  defp order(envs, %{order_bys: []}), do: envs

  defp order(envs, q) do
    specs = Enum.flat_map(q.order_bys, & &1.expr)

    keyed =
      Enum.map(envs, fn env -> {Enum.map(specs, fn {_dir, e} -> Eval.eval(e, env) end), env} end)

    keyed
    |> Enum.sort(fn {ka, _}, {kb, _} -> compare_keys(specs, ka, kb) != :gt end)
    |> Enum.map(&elem(&1, 1))
  end

  defp compare_keys([], _, _), do: :eq

  defp compare_keys([{dir, _} | specs], [a | ra], [b | rb]) do
    case compare_one(dir, a, b) do
      :eq -> compare_keys(specs, ra, rb)
      other -> other
    end
  end

  # PostgreSQL's defaults: NULLS LAST ascending, NULLS FIRST descending.
  defp compare_one(dir, a, b) do
    {desc?, nulls_first?} =
      case dir do
        :asc -> {false, false}
        :asc_nulls_last -> {false, false}
        :asc_nulls_first -> {false, true}
        :desc -> {true, true}
        :desc_nulls_first -> {true, true}
        :desc_nulls_last -> {true, false}
      end

    cond do
      a == b -> :eq
      is_nil(a) -> if nulls_first?, do: :lt, else: :gt
      is_nil(b) -> if nulls_first?, do: :gt, else: :lt
      a < b -> if desc?, do: :gt, else: :lt
      true -> if desc?, do: :lt, else: :gt
    end
  end

  defp distinct(envs, %{distinct: nil}), do: envs

  defp distinct(envs, %{distinct: %{expr: true}} = q),
    do: Enum.uniq_by(envs, fn env -> Enum.map(q.select.fields, &Eval.eval(&1, env)) end)

  defp distinct(envs, %{distinct: %{expr: exprs}}),
    do: Enum.uniq_by(envs, fn env -> Enum.map(exprs, fn {_dir, e} -> Eval.eval(e, env) end) end)

  defp offset_limit(envs, q, params) do
    env = %{rows: {}, params: params, group: nil}
    envs = if q.offset, do: Enum.drop(envs, Eval.eval(q.offset.expr, env)), else: envs
    if q.limit, do: Enum.take(envs, Eval.eval(q.limit.expr, env)), else: envs
  end

  # ------------------------------------------------------------- pushdown

  # Conditions of the form `<column of binding ix> OP <expression over earlier
  # bindings or constants>`. The expression is evaluated now; a `nil` value
  # means SQL's "unknown", which matches nothing, so no pushdown is made for it
  # (the in-memory pass will drop the row).
  defp pushdowns(conj, ix, env, acc) do
    Enum.reduce(conj, acc, fn c, a -> a ++ List.wrap(pushdown(c, ix, env)) end)
  end

  defp pushdown({:==, _, [a, b]}, ix, env), do: eq(a, b, ix, env) || eq(b, a, ix, env)

  defp pushdown({:in, _, [a, b]}, ix, env) do
    with col when not is_nil(col) <- field_of(a, ix),
         true <- constant?(b, ix),
         vs when is_list(vs) <- safe_eval(b, env) do
      vs = vs |> Enum.reject(&is_nil/1) |> Enum.uniq()
      {:in, col, vs}
    else
      _ -> nil
    end
  end

  defp pushdown({:is_nil, _, [a]}, ix, _env) do
    if col = field_of(a, ix), do: {:null, col}
  end

  defp pushdown({:not, _, [{:is_nil, _, [a]}]}, ix, _env) do
    if col = field_of(a, ix), do: {:notnull, col}
  end

  defp pushdown({op, _, [a, b]}, ix, env) when op in [:<, :<=, :>, :>=] do
    cmp(op, a, b, ix, env) || cmp(flip(op), b, a, ix, env)
  end

  defp pushdown(_, _, _), do: nil

  defp eq(a, b, ix, env) do
    with col when not is_nil(col) <- field_of(a, ix),
         true <- constant?(b, ix),
         v when not is_nil(v) <- safe_eval(b, env),
         true <- scalar?(v) do
      {:eq, col, v}
    else
      _ -> nil
    end
  end

  defp cmp(op, a, b, ix, env) do
    with col when not is_nil(col) <- field_of(a, ix),
         true <- constant?(b, ix),
         v when is_number(v) <- safe_eval(b, env) do
      {:cmp, op, col, v}
    else
      _ -> nil
    end
  end

  defp flip(:<), do: :>
  defp flip(:<=), do: :>=
  defp flip(:>), do: :<
  defp flip(:>=), do: :<=

  defp scalar?(v), do: is_binary(v) or is_number(v) or is_boolean(v)

  defp safe_eval(e, env) do
    Eval.eval(e, env)
  rescue
    _ -> :error
  end

  # ------------------------------------------------------------- expressions

  defp field_of({{:., _, [{:&, _, [ix]}, f]}, _, []}, ix), do: f
  defp field_of(_, _), do: nil

  # No reference to binding `ix` or later; evaluable before that row is known.
  defp constant?(e, ix), do: Enum.all?(refs(e), &(&1 < ix)) and not Eval.aggregate?(e)

  defp refs({{:., _, [{:&, _, [i]}, _]}, _, []}), do: [i]
  defp refs({:&, _, [i]}) when is_integer(i), do: [i]
  defp refs({_, _, args}) when is_list(args), do: args |> Enum.flat_map(&refs/1) |> Enum.uniq()
  defp refs(l) when is_list(l), do: l |> Enum.flat_map(&refs/1) |> Enum.uniq()
  defp refs({_, v}), do: refs(v)
  defp refs(_), do: []

  defp where_expr(%{wheres: []}), do: true

  defp where_expr(%{wheres: [first | rest]}) do
    Enum.reduce(rest, first.expr, fn w, acc -> {w.op, [], [acc, w.expr]} end)
  end

  defp conjuncts(%{wheres: wheres}) do
    # Only a chain of `and`s can be split; one `or_where` makes the rest a
    # disjunction, which narrows nothing.
    if Enum.all?(wheres, &(&1.op == :and)),
      do: Enum.flat_map(wheres, &split_and(&1.expr)),
      else: []
  end

  defp split_and({:and, _, [a, b]}), do: split_and(a) ++ split_and(b)
  defp split_and(e), do: [e]

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp table!(q, ix) do
    case elem(q.sources, ix) do
      {table, _schema, _prefix} when is_binary(table) ->
        table

      other ->
        raise Unsupported, "source #{inspect(other)} (subqueries and fragments are not supported)"
    end
  end

  defp join_source!(%{source: {table, _schema}}) when is_binary(table), do: {table, nil, nil}
  defp join_source!(%{source: %Ecto.SubQuery{} = sq}), do: sq
  defp join_source!(%{source: other}), do: raise(Unsupported, "join source #{inspect(other)}")

  # A table is read through the engine (narrowed by `pds`); a subquery is
  # computed whole, and the caller's real predicate does the narrowing.
  defp fetch_source({table, _schema, _prefix}, pds, _params) when is_binary(table),
    do: Engine.fetch(table, pds)

  defp fetch_source(%Ecto.SubQuery{} = sq, _pds, params),
    do: sq |> subquery_rows(params) |> Enum.with_index() |> Enum.map(fn {r, i} -> {i, r} end)

  defp fetch_source(other, _, _), do: raise(Unsupported, "source #{inspect(other)}")

  @doc false
  def subquery_rows(%Ecto.SubQuery{query: q, select: sel}, params) do
    keys = subquery_keys(sel)
    q |> all(params) |> Enum.map(fn row -> keys |> Enum.zip(row) |> Map.new() end)
  end

  @doc "First column of a subquery's rows (`x in subquery(…)`)."
  def subquery_column(%Ecto.SubQuery{} = sq, params) do
    cache_key = {:erlang.phash2(sq.cache), :erlang.phash2(params)}

    case Process.get(:dtlv_sq_cache) do
      %{^cache_key => v} ->
        v

      cache ->
        key = sq.select |> subquery_keys() |> hd()
        v = sq |> subquery_rows(params) |> Enum.map(&Map.fetch!(&1, key))
        if cache, do: Process.put(:dtlv_sq_cache, Map.put(cache, cache_key, v))
        v
    end
  end

  defp subquery_keys({:map, kws}), do: Keyword.keys(kws)
  defp subquery_keys({:struct, _, kws}), do: Keyword.keys(kws)
  defp subquery_keys({:source, _, _, types}), do: Keyword.keys(types)
  defp subquery_keys(other), do: raise(Unsupported, "subquery select #{inspect(other)}")

  defp check!(q) do
    cond do
      q.combinations != [] and (q.order_bys != [] or q.limit != nil or q.offset != nil) ->
        raise Unsupported, "order_by/limit on a union"
      q.with_ctes != nil -> raise Unsupported, "common table expressions"
      q.windows != [] -> raise Unsupported, "window functions"
      true -> :ok
    end
  end
end
