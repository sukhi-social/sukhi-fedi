# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Datalog do
  @moduledoc """
  An `Ecto.Query` written as the Datalog it is.

  Where SQL says `FROM notes n JOIN accounts a ON a.id = n.account_id WHERE
  a.locked = false ORDER BY n.id DESC LIMIT 20`, Datalog says what must hold
  and lets shared variables do the joining:

      [:find (pull ?e0 [*]) (pull ?e1 [*]) ?k0
       :where [?e0 :notes/account_id ?v1] [?e1 :accounts/id ?v1]
              [?e1 :accounts/locked false]
              [?e0 :notes/id ?k0]
       :order-by [?k0 :desc] :limit 20]

  One query, one round trip, every table of the join pulled whole, ordering
  and paging done by the engine on its index.

  `compile/3` translates as much of the query as it can *exactly*. What it
  cannot (a `fragment`, `ilike`, a negation over a nullable column …) comes
  back as `residual` expressions for `Eval` to apply to the rows — still
  correct, but then the engine cannot be trusted with `limit`, so paging is
  left to memory too (`exact?` is false).
  """

  alias SukhiFedi.Datalevin.{Catalog, Edn, Eval}

  defstruct tables: [],
            clauses: [],
            residual: [],
            order: [],
            order_clauses: [],
            limit: nil,
            offset: nil,
            exact?: true,
            empty?: false

  @type t :: %__MODULE__{}

  @cmp [:<, :<=, :>, :>=]

  @doc """
  Plan the Datalog for bindings `0..last` of `q`. `conj` are the `where`
  (and `on`) conjuncts to translate. `tables` are the table names by binding.
  """
  @spec compile([String.t()], [term()], list(), keyword()) :: t()
  def compile(tables, conj, params, opts \\ []) do
    # Joins first: `a.x == b.y` among the top-level conditions makes the two
    # columns one variable (that is what Datalog joins on); every column used
    # at all gets exactly one binding clause, whatever number of conditions
    # mention it.
    {joins, rest} = Enum.split_with(conj, &cross_eq?/1)
    st = %{tables: tables, params: params, vars: join_vars(joins), n: 0}

    {join_clauses, st} =
      Enum.flat_map_reduce(joins, st, fn {:==, _, [a, b]}, st ->
        {ia, ca} = field(a)
        {ib, cb} = field(b)
        {va, st} = var(st, ia, ca)
        {vb, st} = var(st, ib, cb)
        {[bind(st, ia, ca, va), bind(st, ib, cb, vb)], st}
      end)

    {clauses, residual, empty?, st_after} =
      Enum.reduce(rest, {List.flatten(join_clauses), [], false, st}, fn c, {cl, res, empty, st} ->
        case translate(c, st) do
          {:ok, parts, st} -> {cl ++ parts, res, empty, st}
          {:empty, st} -> {cl, res, true, st}
          :residual -> {cl, res ++ [c], empty, st}
        end
      end)

    plan = %__MODULE__{
      tables: tables,
      clauses: Enum.uniq(clauses),
      residual: residual,
      empty?: empty?,
      exact?: residual == []
    }

    if opts[:order], do: order(plan, opts[:order], opts[:limit], opts[:offset], params, st_after), else: plan
  end

  defp cross_eq?({:==, _, [a, b]}) do
    case {field(a), field(b)} do
      {{i, _}, {j, _}} -> i != j
      _ -> false
    end
  end

  defp cross_eq?(_), do: false

  # Union-find over (binding, column) pairs joined by `==`: one variable per class.
  defp join_vars(joins) do
    pairs =
      for {:==, _, [a, b]} <- joins, do: {field(a), field(b)}

    classes =
      Enum.reduce(pairs, [], fn {x, y}, classes ->
        {hit, other} = Enum.split_with(classes, &(x in &1 or y in &1))
        [Enum.uniq([x, y | Enum.concat(hit)]) | other]
      end)

    classes
    |> Enum.with_index()
    |> Enum.flat_map(fn {members, k} -> Enum.map(members, &{&1, "?j#{k}"}) end)
    |> Map.new()
  end

  defp var(st, i, c) do
    case st.vars do
      %{{^i, ^c} => v} -> {v, st}
      vars -> v = "?a#{i}_#{c}"; {v, %{st | vars: Map.put(vars, {i, c}, v)}}
    end
  end

  defp bind(st, i, c, v), do: "[?e#{i} #{attr(st, i, c)} #{v}]"

  # `order_bys`: [{dir, expr}]. Pushed only when every key is a plain column
  # that is NOT NULL (a nullable one would drop its null rows from the join).
  defp order(plan, order_bys, limit, offset, params, st) do
    {keys, _} =
      order_bys
      |> Enum.map_reduce(st, fn
        {dir, {{:., _, [{:&, _, [i]}, col]}, _, []}}, st when dir in [:asc, :desc] ->
          table = Enum.at(plan.tables, i)

          if table && not_null?(table, col) do
            {v, st} = var(st, i, col)
            {{v, dir, bind(st, i, col, v)}, st}
          else
            {nil, st}
          end

        _, st ->
          {nil, st}
      end)

    if order_bys != [] and Enum.all?(keys, & &1) and plan.exact? do
      env = %{rows: {}, params: params, group: nil}

      %{
        plan
        | order: for({v, d, _} <- keys, do: {v, d}),
          order_clauses: for({_, _, c} <- keys, do: c),
          limit: limit && Eval.eval(limit, env),
          offset: offset && Eval.eval(offset, env)
      }
    else
      plan
    end
  end

  defp not_null?(table, col) do
    c = Enum.find(Catalog.table!(table).columns, &(&1.name == to_string(col)))
    c != nil and not c.null
  end

  @doc "Was ordering and paging handed to the engine?"
  @spec paged?(t()) :: boolean()
  def paged?(%__MODULE__{order: o}), do: o != []

  @doc "The Datalog text."
  @spec to_edn(t(), String.t()) :: String.t()
  def to_edn(%__MODULE__{} = p, extra \\ "") do
    n = length(p.tables)
    pulls = Enum.map_join(0..(n - 1)//1, " ", &"(pull ?e#{&1} [*])")
    keys = Enum.map_join(p.order, "", fn {v, _} -> " " <> v end)
    where = where_text(p) <> extra

    tail =
      if p.order == [] do
        ""
      else
        o = Enum.map_join(p.order, " ", fn {v, d} -> "#{v} #{Edn.literal(d)}" end)
        " :order-by [#{o}]" <> if(p.limit, do: " :limit #{p.limit}", else: "") <> if(p.offset, do: " :offset #{p.offset}", else: "")
      end

    "[:find #{pulls}#{keys} :where #{where}#{tail}]"
  end

  @doc "Highest root entity id the plan can match (to split an oversized answer)."
  @spec max_edn(t()) :: String.t()
  def max_edn(%__MODULE__{} = p), do: "[:find (max ?e0) . :where #{where_text(%{p | order: [], order_clauses: []})}]"

  defp where_text(p) do
    positive = positive_vars(p)

    anchors =
      for i <- 0..(length(p.tables) - 1)//1, not MapSet.member?(positive, i) do
        t = Enum.at(p.tables, i)
        "[?e#{i} #{Edn.literal(SukhiFedi.Datalevin.Engine.anchor_attr(t))} _]"
      end

    Enum.join(anchors ++ p.clauses ++ p.order_clauses, " ")
  end

  # Entity variables that some clause already pins to a table's attribute.
  defp positive_vars(p) do
    text = Enum.join(p.clauses ++ p.order_clauses, " ")

    for i <- 0..(length(p.tables) - 1)//1,
        Regex.match?(~r/\[\?e#{i} :[^ \]]+ /, text),
        into: MapSet.new(),
        do: i
  end

  # --------------------------------------------------------------- translate
  #
  # Each returns `{:ok, [clause], st}`, `{:empty, st}` (can match nothing) or
  # `:residual` (left to `Eval`).

  defp translate({:and, _, [a, b]}, st) do
    with {:ok, ta, st} <- translate(a, st), {:ok, tb, st} <- translate(b, st) do
      {:ok, ta ++ tb, st}
    else
      other -> other
    end
  end

  # `or` of exact leaves, scoped over the entity variables it mentions.
  defp translate({:or, _, [a, b]} = e, st) do
    vars = entity_vars(e)

    with {:ok, ta, _} <- translate_branch(a, st), {:ok, tb, _} <- translate_branch(b, st) do
      {:ok, ["(or-join [#{Enum.join(vars, " ")}] #{ta} #{tb})"], st}
    else
      _ -> :residual
    end
  end

  defp translate({:==, _, [a, b]}, st) do
    case {field(a), field(b), const(a, st), const(b, st)} do
      {{i, c}, nil, _, {:ok, v}} -> eq(i, c, v, st)
      {nil, {i, c}, {:ok, v}, _} -> eq(i, c, v, st)
      {{i, ca}, {j, cb}, _, _} when i == j -> same_row(i, ca, cb, st)
      _ -> :residual
    end
  end

  defp translate({:!=, _, [a, b]}, st) do
    case {field(a), const(b, st)} do
      {{i, c}, {:ok, v}} when not is_nil(v) -> pred(st, i, c, fn x -> "[(not= #{x} #{Edn.literal(v)})]" end)
      _ -> :residual
    end
  end

  defp translate({op, _, [a, b]}, st) when op in @cmp do
    case {field(a), field(b), const(a, st), const(b, st)} do
      {{_, _} = f, nil, _, {:ok, v}} -> range(f, op, v, st)
      {nil, {_, _} = f, {:ok, v}, _} -> range(f, flip(op), v, st)
      _ -> :residual
    end
  end

  defp translate({:in, _, [a, b]}, st) do
    with {i, c} <- field(a),
         {:ok, list} when is_list(list) <- const(b, st) do
      vs = list |> Enum.reject(&is_nil/1) |> Enum.uniq()

      if vs == [] do
        {:empty, st}
      else
        set = "\#{" <> Enum.map_join(vs, " ", &Edn.literal/1) <> "}"
        pred(st, i, c, fn x -> "[(contains? #{set} #{x})]" end)
      end
    else
      _ -> :residual
    end
  end

  defp translate({:is_nil, _, [a]}, st) do
    case field(a) do
      {i, c} -> {:ok, ["[(missing? $ ?e#{i} #{attr(st, i, c)})]"], st}
      _ -> :residual
    end
  end

  defp translate({:not, _, [{:is_nil, _, [a]}]}, st) do
    case field(a) do
      {i, c} ->
        {v, st} = var(st, i, c)
        {:ok, [bind(st, i, c, v)], st}

      _ ->
        :residual
    end
  end

  defp translate({:like, _, [a, b]}, st) do
    with {i, c} <- field(a),
         {:ok, pat} when is_binary(pat) <- const(b, st) do
      pred(st, i, c, fn x -> "[(like #{x} #{Edn.literal(like_pattern(pat))})]" end)
    else
      _ -> :residual
    end
  end

  defp translate(true, st), do: {:ok, [], st}
  defp translate(_, _), do: :residual

  defp translate_branch(e, st) do
    case translate(e, st) do
      {:ok, t, st} -> {:ok, "(and #{Enum.join(t, " ")})", st}
      other -> other
    end
  end

  # The column's variable, bound once, then a predicate on it.
  defp pred(st, i, c, fun) do
    {v, st} = var(st, i, c)
    {:ok, [bind(st, i, c, v), fun.(v)], st}
  end

  # `(= ?x false)` makes dtlv 1.2.10 fail ("Can't pop empty vector").
  defp eq(i, c, v, st) when is_boolean(v), do: pred(st, i, c, fn x -> "[(#{v}? #{x})]" end)

  defp eq(i, c, v, st) when not is_nil(v) do
    if scalar?(v), do: pred(st, i, c, fn x -> "[(= #{x} #{Edn.literal(v)})]" end), else: :residual
  end

  defp eq(_, _, _, _), do: :residual

  defp same_row(i, ca, cb, st) do
    {va, st} = var(st, i, ca)
    {vb, st} = var(st, i, cb)
    {:ok, [bind(st, i, ca, va), bind(st, i, cb, vb), "[(= #{va} #{vb})]"], st}
  end

  defp range({i, c}, op, v, st) when is_number(v) or is_binary(v),
    do: pred(st, i, c, fn x -> "[(#{op} #{x} #{Edn.literal(v)})]" end)

  defp range(_, _, _, _), do: :residual

  # SQL LIKE (backslash escapes) → Datalevin like (`!` escapes).
  defp like_pattern(sql) do
    sql
    |> String.replace("!", "!!")
    |> then(&Regex.replace(~r/\\(.)/s, &1, "!\\1"))
  end

  defp flip(:<), do: :>
  defp flip(:<=), do: :>=
  defp flip(:>), do: :<
  defp flip(:>=), do: :<=

  defp scalar?(v), do: is_binary(v) or is_number(v) or is_boolean(v)

  defp attr(st, i, c), do: Edn.literal(Catalog.attr(Enum.at(st.tables, i), c))

  defp field({{:., _, [{:&, _, [i]}, f]}, _, []}), do: {i, f}
  defp field(_), do: nil

  # An expression that mentions no row: evaluable now.
  defp const(e, st) do
    if refs?(e) do
      :error
    else
      {:ok, Eval.eval(e, %{rows: {}, params: st.params, group: nil})}
    end
  rescue
    _ -> :error
  end

  defp refs?({{:., _, [{:&, _, [_]}, _]}, _, []}), do: true
  defp refs?({_, _, args}) when is_list(args), do: Enum.any?(args, &refs?/1)
  defp refs?(l) when is_list(l), do: Enum.any?(l, &refs?/1)
  defp refs?({_, v}), do: refs?(v)
  defp refs?(_), do: false

  defp entity_vars(e), do: e |> binds() |> Enum.uniq() |> Enum.sort() |> Enum.map(&"?e#{&1}")

  defp binds({{:., _, [{:&, _, [i]}, _]}, _, []}), do: [i]
  defp binds({_, _, args}) when is_list(args), do: Enum.flat_map(args, &binds/1)
  defp binds(l) when is_list(l), do: Enum.flat_map(l, &binds/1)
  defp binds(_), do: []
end
