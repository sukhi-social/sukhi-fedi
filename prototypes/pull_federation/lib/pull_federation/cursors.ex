# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Cursors do
  @moduledoc """
  Cursor maps: `%{key => etag}`, one opaque ETag per sequence key.

  The receiver can only ask one question of a token: "is it the same as
  mine?" It cannot order two tokens, count them, or guess the next one.
  Both the notification path and the pull path go through `changed/2`,
  so the two cannot disagree.
  """

  @type t :: %{String.t() => String.t()}

  @doc "Keys whose announced token differs from ours (missing counts as different)."
  @spec changed(t, t) :: t
  def changed(have, announced) do
    for {key, token} <- announced, Map.get(have, key) != token, into: %{}, do: {key, token}
  end

  @doc "Adopt the newer tokens. Last write wins: there is no order to compare."
  @spec merge(t, t) :: t
  def merge(have, seen), do: Map.merge(have, seen)

  @doc "Shape check for untrusted input. Parsed once, at the edge."
  @spec parse(term) :: {:ok, t} | :error
  def parse(map) when is_map(map) and map_size(map) <= 1_000 do
    if Enum.all?(map, &valid_entry?/1), do: {:ok, map}, else: :error
  end

  def parse(_), do: :error

  defp valid_entry?({key, token}),
    do: is_binary(key) and is_binary(token) and byte_size(token) in 1..64
end
