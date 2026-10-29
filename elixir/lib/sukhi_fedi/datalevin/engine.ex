# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Engine do
  @moduledoc """
  Rows in and out of Datalevin. Nothing here knows about Ecto.

  A row is an entity whose attributes are `:"table/column"`; a `Row` is a map
  keyed by column atoms holding stored values (see `Types`); an absent
  attribute is `nil`. Reads are *pushdowns* — a small list of conditions that
  narrow what dtlv returns — and every read is a plain Datalog query, so any
  number of them can be sent together with `fetch_many/1`.

      {:eq, col, value}        {:in, col, [value]}
      {:cmp, :< | :<= | :> | :>=, col, number}
      {:null, col}             {:notnull, col}

  Pushdowns are only ever a pre-filter. The caller still evaluates the real
  predicate on what comes back (`Eval`).
  """

  alias SukhiFedi.Datalevin.{Catalog, Client, Edn}

  @type row :: %{optional(atom()) => term()}
  @type pushdown ::
          {:eq, atom(), term()}
          | {:in, atom(), [term()]}
          | {:cmp, atom(), atom(), number()}
          | {:null, atom()}
          | {:notnull, atom()}

  @in_chunk 400

  # ------------------------------------------------------------------ reads

  @doc "`[{eid, row}]` of the table's rows meeting the pushdowns."
  @spec fetch(String.t(), [pushdown()]) :: [{integer(), row()}]
  def fetch(table, pushdowns), do: hd(fetch_many([{table, pushdowns}]))

  @doc """
  Many reads at once, one result list each, in order. A `{:in, col, values}`
  with more than a chunk of values becomes several queries; they all travel
  in the same pipeline and are merged back.
  """
  @spec fetch_many([{String.t(), [pushdown()]}]) :: [[{integer(), row()}]]
  def fetch_many(specs) do
    # Expand big `in`s into chunks, remembering which request each came from.
    expanded =
      specs
      |> Enum.with_index()
      |> Enum.flat_map(fn {{table, pds}, i} ->
        pds
        |> chunk_in()
        |> Enum.map(&{i, table, &1})
      end)

    # An empty `IN ()` matches nothing; don't ask.
    {empty, expanded} =
      Enum.split_with(expanded, fn {_, _, pds} -> Enum.any?(pds, &match?({:in, _, []}, &1)) end)

    _ = empty
    answers = Client.query_many(Enum.map(expanded, fn {_, t, pds} -> find_pull(t, pds) end))

    merged =
      expanded
      |> Enum.zip(answers)
      |> Enum.reduce(%{}, fn {{i, table, pds}, ans}, acc ->
        rows =
          case ans do
            {:ok, rs} -> rs
            {:error, %{"code" => ":result-too-large"}} -> paged(table, pds)
            {:error, e} -> raise "datalevin query failed: #{inspect(e)}"
          end

        Map.update(acc, i, decode_all(table, rows), &(&1 ++ decode_all(table, rows)))
      end)

    for i <- 0..(length(specs) - 1)//1, do: merged |> Map.get(i, []) |> Enum.uniq_by(&elem(&1, 0))
  end

  defp chunk_in(pds) do
    case Enum.split_with(pds, &match?({:in, _, vs} when length(vs) > @in_chunk, &1)) do
      {[], _} ->
        [pds]

      {[{:in, col, vs} | more], rest} ->
        vs
        |> Enum.chunk_every(@in_chunk)
        |> Enum.flat_map(fn c -> chunk_in([{:in, col, c} | more ++ rest]) end)
    end
  end

  defp decode_all(table, rows) do
    prefix = ":" <> table <> "/"

    Enum.map(rows, fn
      [m] -> row(prefix, m)
      m when is_map(m) -> row(prefix, m)
    end)
  end

  @doc "A pulled entity map → `{eid, row}`."
  @spec decode(String.t(), map()) :: {integer(), row()}
  def decode(table, m), do: row(":" <> table <> "/", m)

  defp row(prefix, m) do
    {eid, attrs} = Map.pop(m, ":db/id")

    row =
      Enum.reduce(attrs, %{}, fn {k, v}, acc ->
        if String.starts_with?(k, prefix),
          do:
            Map.put(
              acc,
              String.to_atom(binary_part(k, byte_size(prefix), byte_size(k) - byte_size(prefix))),
              Edn.decode(v)
            ),
          else: acc
      end)

    {eid, row}
  end

  defp find_pull(table, pds), do: "[:find (pull ?e [*]) :where #{where(table, pds)}]"

  @doc false
  def where(table, pds) do
    clauses = Enum.with_index(pds) |> Enum.map(fn {pd, n} -> clause(table, pd, n) end)

    anchored? = Enum.any?(pds, &(elem(&1, 0) != :null))
    anchor = if anchored?, do: [], else: ["[?e #{Edn.literal(anchor_attr(table))} _]"]
    Enum.join(anchor ++ clauses, " ")
  end

  @doc false
  def anchor_attr(table) do
    t = Catalog.table!(table)
    col = if t.pk != [], do: hd(t.pk), else: Enum.find_value(t.columns, &(not &1.null && &1.name))
    Catalog.attr(table, col || hd(t.columns).name)
  end

  defp clause(t, {:eq, c, v}, _), do: "[?e #{attr(t, c)} #{Edn.literal(v)}]"
  defp clause(t, {:notnull, c}, _), do: "[?e #{attr(t, c)} _]"
  defp clause(t, {:null, c}, _), do: "[(missing? $ ?e #{attr(t, c)})]"

  defp clause(t, {:in, c, vs}, _),
    do: "(or " <> Enum.map_join(vs, " ", &"[?e #{attr(t, c)} #{Edn.literal(&1)}]") <> ")"

  defp clause(t, {:cmp, op, c, v}, n),
    do: "[?e #{attr(t, c)} ?v#{n}] [(#{op} ?v#{n} #{Edn.literal(v)})]"

  defp attr(table, col), do: Edn.literal(Catalog.attr(table, col))

  # More matches than dtlv will return in one answer: split the entity-id
  # range until each slice fits.
  defp paged(table, pds) do
    case Client.query("[:find (max ?e) . :where #{where(table, pds)}]") do
      {:ok, max} when is_integer(max) -> slice(table, pds, 0, max + 1)
      _ -> []
    end
  end

  defp slice(table, pds, lo, hi) do
    q = "[:find (pull ?e [*]) :where #{where(table, pds)} [(>= ?e #{lo})] [(< ?e #{hi})]]"

    case Client.query(q) do
      {:ok, rows} ->
        rows

      {:error, %{"code" => ":result-too-large"}} when hi - lo > 1 ->
        mid = div(lo + hi, 2)
        slice(table, pds, lo, mid) ++ slice(table, pds, mid, hi)

      {:error, e} ->
        raise "datalevin query failed: #{inspect(e)}"
    end
  end

  @doc "How many rows meet the pushdowns."
  @spec count(String.t(), [pushdown()]) :: non_neg_integer()
  def count(table, pds) do
    case Client.query("[:find (count ?e) . :where #{where(table, pds)}]") do
      {:ok, n} when is_integer(n) -> n
      {:ok, nil} -> 0
      {:error, e} -> raise "datalevin query failed: #{inspect(e)}"
    end
  end

  # ----------------------------------------------------------------- writes

  @doc "The entity map to transact for a row (nil values are simply absent)."
  @spec entity(String.t(), row(), integer() | nil) :: map()
  def entity(table, row, db_id \\ nil) do
    base = if db_id, do: %{":db/id" => db_id}, else: %{}

    Enum.reduce(row, base, fn
      {_k, nil}, acc -> acc
      {k, v}, acc -> Map.put(acc, ":#{table}/#{k}", enc(v))
    end)
  end

  defp enc(i) when is_integer(i), do: Edn.encode_int(i)
  defp enc(v), do: v

  @doc "Transact and return the new entity id for tempid `-1`, if any."
  @spec transact([term()]) :: {:ok, map()} | {:error, term()}
  def transact(tx), do: Client.transact(tx)

  @doc "The tx-data that makes `table`'s entity `eid` look like `new`, given it looks like `old`."
  @spec diff(String.t(), integer(), row(), row()) :: {[term()], [term()]}
  def diff(table, eid, old, new) do
    keys = Enum.uniq(Map.keys(old) ++ Map.keys(new))

    Enum.reduce(keys, {[], []}, fn k, {d, u} ->
      a = ":#{table}/#{k}"
      {o, n} = {Map.get(old, k), Map.get(new, k)}

      cond do
        o == n ->
          {d, u}

        is_nil(n) ->
          {[[":db.fn/retractAttribute", eid, a] | d], [[":db/add", eid, a, enc(o)] | u]}

        is_nil(o) ->
          {[[":db/add", eid, a, enc(n)] | d], [[":db.fn/retractAttribute", eid, a] | u]}

        true ->
          {[[":db/add", eid, a, enc(n)] | d], [[":db/add", eid, a, enc(o)] | u]}
      end
    end)
  end
end
