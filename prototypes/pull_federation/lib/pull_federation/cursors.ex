# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Cursors do
  @moduledoc """
  Cursor maps: `%{key => etag}`, one ETag per sequence key.

  Opaque tokens answer one question: "is it the same as mine?". Ordered
  tokens (see `Etag`) also say which is newer.
  Both the notification path and the pull path go through `changed/2`,
  so the two cannot disagree.
  """

  alias PullFederation.Etag

  @type t :: %{String.t() => String.t()}

  @doc """
  Keys whose announced token is news to us. Missing, different and
  unordered, or ahead of ours (both ordered): changed. Equal, or behind
  ours (a stale ordered notification): not.
  """
  @spec changed(t, t) :: t
  def changed(have, announced) do
    for {key, token} <- announced, news?(Map.get(have, key), token), into: %{}, do: {key, token}
  end

  defp news?(nil, _announced), do: true
  defp news?(have, announced), do: Etag.compare(have, announced) in [:lt, :unordered]

  @doc "Adopt the newer tokens. Ordered tokens never move backwards; opaque ones are last-write-wins."
  @spec merge(t, t) :: t
  def merge(have, seen) do
    Map.merge(have, seen, fn _key, old, new ->
      case Etag.compare(old, new) do
        :gt -> old
        _ -> new
      end
    end)
  end

  @doc "Shape check for untrusted input. Parsed once, at the edge."
  @spec parse(term) :: {:ok, t} | :error
  def parse(map) when is_map(map) and map_size(map) <= 1_000 do
    if Enum.all?(map, &valid_entry?/1), do: {:ok, map}, else: :error
  end

  def parse(_), do: :error

  defp valid_entry?({key, token}), do: is_binary(key) and Etag.valid?(token)
end
