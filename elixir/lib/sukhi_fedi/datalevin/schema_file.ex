# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.SchemaFile do
  @moduledoc """
  Reads `priv/datalevin/schema.edn`, the graph schema (docs/DATALEVIN_SCHEMA.md),
  into `%{attr_atom => %{key_atom => value}}`.

  The reader knows only the EDN the file uses: `;;` comments, one top-level
  map, nested maps and vectors, keywords, booleans, strings and integers.
  `check/1` is the structural check the tests run, so the file cannot drift
  into something `dtlv` would refuse.
  """

  @type schema :: %{atom() => %{atom() => term()}}

  @path "priv/datalevin/schema.edn"

  @spec read() :: schema()
  def read,
    do:
      :sukhi_fedi
      |> :code.priv_dir()
      |> Path.join("datalevin/schema.edn")
      |> File.read!()
      |> parse()

  @doc false
  def path, do: @path

  @spec parse(String.t()) :: schema()
  def parse(text) do
    text
    |> String.replace(~r/;;[^\n]*/u, "")
    |> tokens()
    |> then(fn tokens ->
      {value, []} = value(tokens)
      value
    end)
  end

  @doc "Problems in `schema`; `[]` when it is sound."
  @spec check(schema()) :: [String.t()]
  def check(schema) do
    Enum.flat_map(schema, fn {attr, props} ->
      type = props[:"db/valueType"]

      [
        if(is_nil(type), do: "#{attr}: no :db/valueType"),
        if(type == :"db.type/tuple" and not is_list(props[:"db/tupleAttrs"]),
          do: "#{attr}: tuple without :db/tupleAttrs"
        ),
        if(props[:"db/fulltext"] == true and props[:"db.fulltext/autoDomain"] != true,
          do: "#{attr}: fulltext without :db.fulltext/autoDomain (fulltext queries raise)"
        )
      ] ++
        for part <- List.wrap(props[:"db/tupleAttrs"]), not Map.has_key?(schema, part) do
          "#{attr}: tuple part #{part} is not defined"
        end ++
        for part <- List.wrap(props[:"db/tupleAttrs"]),
            props[:"db/unique"] == :"db.unique/identity",
            schema[part][:"db/cardinality"] == :"db.cardinality/many" do
          "#{attr}: identity tuple over cardinality-many #{part}"
        end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp tokens(text) do
    ~r/"(?:[^"\\]|\\.)*"|[{}\[\]]|[^\s{}\[\]"]+/u |> Regex.scan(text) |> Enum.map(&hd/1)
  end

  defp value(["{" | rest]), do: map(rest, %{})
  defp value(["[" | rest]), do: vector(rest, [])
  defp value(["true" | rest]), do: {true, rest}
  defp value(["false" | rest]), do: {false, rest}
  defp value(["nil" | rest]), do: {nil, rest}
  defp value([":" <> kw | rest]), do: {String.to_atom(kw), rest}
  defp value(["\"" <> _ = s | rest]), do: {s |> String.slice(1..-2//1), rest}

  defp value([tok | rest]) do
    case Integer.parse(tok) do
      {n, ""} -> {n, rest}
      _ -> raise ArgumentError, "schema.edn: unexpected #{inspect(tok)}"
    end
  end

  defp map(["}" | rest], acc), do: {acc, rest}

  defp map(tokens, acc) do
    {k, rest} = value(tokens)
    {v, rest} = value(rest)
    map(rest, Map.put(acc, k, v))
  end

  defp vector(["]" | rest], acc), do: {Enum.reverse(acc), rest}

  defp vector(tokens, acc) do
    {v, rest} = value(tokens)
    vector(rest, [v | acc])
  end
end
