# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Adapter do
  @moduledoc """
  The Ecto adapter callbacks for the Datalevin store.

  Not registered with Ecto directly: `SukhiFedi.Store.Adapter` is, and hands
  each call here when the store is Datalevin. Every function therefore takes
  the same arguments the `Ecto.Adapter.*` callback of that name does.

  Reads go through `Query`, writes through `Writer`; this module only
  translates between Ecto's calling convention and theirs.
  """

  alias SukhiFedi.Datalevin.{Query, Types, Writer}

  # ------------------------------------------------------------- lifecycle

  def init(_config) do
    spec = %{
      id: SukhiFedi.Datalevin.Supervisor,
      start: {SukhiFedi.Datalevin.Supervisor, :start_link, [[]]},
      type: :supervisor
    }

    {:ok, spec, %{store: :datalevin, telemetry: nil, opts: []}}
  end

  def checkout(_meta, _opts, fun), do: fun.()
  def checked_out?(_meta), do: false

  defdelegate loaders(primitive, type), to: Types
  defdelegate dumpers(primitive, type), to: Types

  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.generate()
  def autogenerate(:binary_id), do: Ecto.UUID.bingenerate()

  # ---------------------------------------------------------------- queries

  def prepare(kind, query), do: {:nocache, {kind, query}}

  def execute(_meta, _query_meta, {:nocache, {:all, query}}, params, _opts) do
    rows = Query.all(query, params)
    {length(rows), rows}
  end

  def execute(_meta, _query_meta, {:nocache, {:update_all, query}}, params, _opts),
    do: Query.update_all(query, params)

  def execute(_meta, _query_meta, {:nocache, {:delete_all, query}}, params, _opts),
    do: Query.delete_all(query, params)

  def stream(_meta, _query_meta, {:nocache, {:all, query}}, params, _opts) do
    Stream.map([Query.all(query, params)], fn rows -> {length(rows), rows} end)
  end

  # ----------------------------------------------------------------- schema

  def insert(_meta, %{source: source}, params, on_conflict, returning, _opts) do
    Writer.insert(source, params, on_conflict, returning)
  end

  def update(_meta, %{source: source}, fields, filters, returning, _opts) do
    Writer.update(source, fields, filters, returning)
  end

  def delete(_meta, %{source: source}, filters, returning, _opts) do
    Writer.delete(source, filters, returning)
  end

  def insert_all(
        _meta,
        %{source: source},
        _header,
        rows,
        on_conflict,
        returning,
        placeholders,
        _opts
      ) do
    results =
      Writer.transaction_if_needed(fn ->
        Enum.map(rows, fn row ->
          params = Enum.map(row, fn {k, v} -> {k, placeholder(v, placeholders)} end)

          case Writer.insert(source, params, on_conflict, returning) do
            {:ok, ret} ->
              ret

            {:invalid, [{type, name} | _]} ->
              raise Ecto.ConstraintError, type: type, constraint: name, changeset: nil
          end
        end)
      end)

    inserted = Enum.reject(results, &(&1 == [] and returning == [] and false))

    if returning == [],
      do: {length(inserted), nil},
      else: {length(inserted), Enum.map(inserted, &Keyword.values/1)}
  end

  defp placeholder({:placeholder, ix}, placeholders), do: Enum.at(placeholders, ix - 1)

  defp placeholder({%Ecto.Query{}, _}, _),
    do: raise(SukhiFedi.Datalevin.Eval.Unsupported, "insert_all with a query value")

  defp placeholder(v, _), do: v

  # ----------------------------------------------------------- transactions

  def transaction(_meta, _opts, fun), do: Writer.transaction(fun)
  def in_transaction?(_meta), do: Writer.in_transaction?()
  def rollback(_meta, value), do: Writer.rollback(value)
end
