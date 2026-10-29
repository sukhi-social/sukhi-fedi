# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Catalog do
  @moduledoc """
  What the SQL schema says, as data the Datalevin store can use.

  Read from `priv/datalevin/catalog.exs`, a snapshot `mix sukhi.datalevin.catalog`
  takes of a migrated Postgres. The store never reads migrations itself.

  Each table is `%{columns, pk, unique, fks}`; see the mix task for the shape.
  Column and table names are strings here — the Ecto side speaks atoms, and
  `attr/2` is the single place a pair becomes a Datalevin attribute.
  """

  @path Path.expand("../../../priv/datalevin/catalog.exs", __DIR__)
  @external_resource @path

  @tables (case File.read(@path) do
             {:ok, _} -> @path |> Code.eval_file() |> elem(0)
             _ -> %{}
           end)

  @type table :: %{
          columns: [map()],
          pk: [String.t()],
          unique: [map()],
          fks: [map()]
        }

  @doc "All table names."
  @spec tables() :: [String.t()]
  def tables, do: Map.keys(@tables)

  @spec table(String.t()) :: table() | nil
  def table(name), do: Map.get(@tables, name)

  @spec table!(String.t()) :: table()
  def table!(name) do
    table(name) ||
      raise ArgumentError,
            "table #{inspect(name)} is not in priv/datalevin/catalog.exs " <>
              "(run `mix sukhi.migrate && mix sukhi.datalevin.catalog`)"
  end

  @doc "The Datalevin attribute (an atom) of a column."
  @spec attr(String.t(), String.t() | atom()) :: atom()
  def attr(table, column), do: :"#{table}/#{column}"

  @doc "Column names of a table, as atoms, in table order."
  @spec fields(String.t()) :: [atom()]
  def fields(table), do: Enum.map(table!(table).columns, &String.to_atom(&1.name))

  @doc "Postgres type of a column."
  @spec type(String.t(), String.t() | atom()) :: String.t() | nil
  def type(table, column) do
    column = to_string(column)
    Enum.find_value(table!(table).columns, &(&1.name == column && &1.type))
  end

  @doc """
  The attribute definitions to hand `open_database`: one per column, typed so
  that range queries compare numbers as numbers. Counters for generated ids
  live under `:seq/*`.
  """
  @spec dtlv_schema() :: map()
  def dtlv_schema do
    cols =
      for {table, t} <- @tables, c <- t.columns, into: %{} do
        {":" <> Atom.to_string(attr(table, c.name)), attr_def(table, t, c)}
      end

    Map.merge(cols, %{
      ":seq/table" => %{":db/valueType" => ":db.type/string", ":db/unique" => ":db.unique/identity"},
      ":seq/next" => %{":db/valueType" => ":db.type/long"}
    })
  end

  defp attr_def(_table, t, c) do
    base = %{":db/valueType" => value_type(c.type)}
    if c.name == "id" and t.pk == ["id"], do: Map.put(base, ":db/unique", ":db.unique/identity"), else: base
  end

  @doc "Datalevin value type of a Postgres type; what we store is described in `Types`."
  @spec value_type(String.t()) :: String.t()
  def value_type(t) when t in ["bigint", "integer", "smallint", "date"], do: ":db.type/long"
  def value_type("timestamp without time zone"), do: ":db.type/long"
  def value_type("timestamp with time zone"), do: ":db.type/long"
  def value_type("boolean"), do: ":db.type/boolean"
  def value_type(t) when t in ["double precision", "real"], do: ":db.type/double"
  def value_type(_), do: ":db.type/string"

  @doc "Unique indexes (not the primary key) that the store enforces itself."
  @spec unique(String.t()) :: [map()]
  def unique(table), do: table!(table).unique

  @doc "Foreign keys elsewhere that point at `table`: `[{child_table, fk}]`."
  @spec referencing(String.t()) :: [{String.t(), map()}]
  def referencing(table) do
    persistent_term(:referencing, fn ->
      for {child, t} <- @tables, fk <- t.fks, reduce: %{} do
        acc -> Map.update(acc, fk.ref_table, [{child, fk}], &[{child, fk} | &1])
      end
    end)
    |> Map.get(table, [])
  end

  @doc "Column default as a tagged value, or `nil` for none. See `Types.default/1`."
  @spec default(String.t(), String.t()) :: String.t() | nil
  def default(table, column) do
    Enum.find_value(table!(table).columns, &(&1.name == column && &1.default))
  end

  defp persistent_term(key, fun) do
    k = {__MODULE__, key}

    case :persistent_term.get(k, :none) do
      :none ->
        v = fun.()
        :persistent_term.put(k, v)
        v

      v ->
        v
    end
  end
end
