# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Edn do
  @moduledoc """
  The two directions of dtlv's JSON surface.

  Going in, a Datalog query is EDN *text*, and values are written into it as
  literals rather than passed as `inputs`: the JSON API reads an input string
  that starts with `":"` as a keyword, and a post that begins with `:smile:`
  must stay a string. A string literal inside the query text is always a
  string.

  Coming out, JSON carries a few wrappers: `{"~i64": "…"}` for integers
  beyond 2^53, `{"~set": […]}` for a relation result.
  """

  @doc "EDN text for a value."
  @spec literal(term()) :: String.t()
  def literal(nil), do: "nil"
  def literal(true), do: "true"
  def literal(false), do: "false"
  def literal(n) when is_integer(n), do: Integer.to_string(n)
  def literal(f) when is_float(f), do: Float.to_string(f)
  def literal(a) when is_atom(a), do: ":" <> Atom.to_string(a)
  def literal(s) when is_binary(s), do: [?", escape(s, []), ?"] |> IO.iodata_to_binary()

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?\\, r::binary>>, acc), do: escape(r, ["\\\\" | acc])
  defp escape(<<?", r::binary>>, acc), do: escape(r, ["\\\"" | acc])
  defp escape(<<?\n, r::binary>>, acc), do: escape(r, ["\\n" | acc])
  defp escape(<<?\r, r::binary>>, acc), do: escape(r, ["\\r" | acc])
  defp escape(<<?\t, r::binary>>, acc), do: escape(r, ["\\t" | acc])

  defp escape(<<c, r::binary>>, acc) when c < 0x20,
    do: escape(r, [["\\u", c |> Integer.to_string(16) |> String.pad_leading(4, "0")] | acc])

  defp escape(<<c::utf8, r::binary>>, acc), do: escape(r, [<<c::utf8>> | acc])

  @doc "JSON value out of dtlv → plain Elixir term."
  @spec decode(term()) :: term()
  def decode(:null), do: nil
  def decode(%{"~i64" => s}) when is_binary(s), do: String.to_integer(s)
  def decode(%{"~set" => l}) when is_list(l), do: Enum.map(l, &decode/1)
  def decode(%{"~map" => pairs}), do: Map.new(pairs, fn [k, v] -> {decode(k), decode(v)} end)
  def decode(l) when is_list(l), do: Enum.map(l, &decode/1)
  def decode(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, decode(v)} end)
  def decode(other), do: other

  @doc "Integer into a transaction/JSON value: beyond 2^53 it needs the `~i64` wrapper."
  @spec encode_int(integer()) :: integer() | map()
  def encode_int(n) when abs(n) <= 9_007_199_254_740_991, do: n
  def encode_int(n), do: %{"~i64" => Integer.to_string(n)}
end
