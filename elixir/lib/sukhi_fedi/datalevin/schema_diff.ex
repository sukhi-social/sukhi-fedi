# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.SchemaDiff do
  @moduledoc """
  What changed between two Datalevin schemas, and whether a store can simply
  open with the newer one.

  Schemas here are the wire form `datalevin_open_database` takes:
  `%{":ns/name" => %{":db/valueType" => ":db.type/string", ...}}`
  (`Catalog.dtlv_schema/0`, `SchemaFile.to_dtlv/1`).

  One rule decides everything: **only a new attribute is additive.** A
  removed attribute leaves data nobody reads, and a changed one may no longer
  fit the data stored under it, so both need a migration that says what
  happens to that data. `:db/doc` is documentation and is ignored.
  """

  @type schema :: %{String.t() => %{String.t() => term()}}
  @type t :: %{
          added: [String.t()],
          removed: [String.t()],
          changed: [{String.t(), old :: map(), new :: map()}]
        }

  @ignored [":db/doc"]

  @doc "The difference from `old` to `new`; every list is sorted."
  @spec diff(schema(), schema()) :: t()
  def diff(old, new) do
    old_keys = old |> Map.keys() |> MapSet.new()
    new_keys = new |> Map.keys() |> MapSet.new()

    changed =
      for k <- MapSet.intersection(old_keys, new_keys),
          strip(old[k]) != strip(new[k]),
          do: {k, old[k], new[k]}

    %{
      added: new_keys |> MapSet.difference(old_keys) |> Enum.sort(),
      removed: old_keys |> MapSet.difference(new_keys) |> Enum.sort(),
      changed: Enum.sort_by(changed, &elem(&1, 0))
    }
  end

  @doc "May a store at the old schema open with the new one as it is?"
  @spec additive?(t()) :: boolean()
  def additive?(%{removed: [], changed: []}), do: true
  def additive?(%{}), do: false

  @doc "Nothing differs at all."
  @spec empty?(t()) :: boolean()
  def empty?(%{added: [], removed: [], changed: []}), do: true
  def empty?(%{}), do: false

  @doc "The attributes a migration has to answer for: removed and changed ones."
  @spec breaking(t()) :: [String.t()]
  def breaking(%{removed: removed, changed: changed}),
    do: Enum.sort(removed ++ Enum.map(changed, &elem(&1, 0)))

  @doc "A diff in a few lines, for an error message."
  @spec describe(t()) :: String.t()
  def describe(%{added: added, removed: removed, changed: changed}) do
    [
      list("removed", removed),
      list("changed", Enum.map(changed, &elem(&1, 0))),
      list("added", added)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp list(_label, []), do: nil

  defp list(label, attrs) do
    shown = attrs |> Enum.take(8) |> Enum.join(", ")
    more = if length(attrs) > 8, do: " (+#{length(attrs) - 8} more)", else: ""
    "#{label}: #{shown}#{more}"
  end

  defp strip(props), do: Map.drop(props, @ignored)
end
