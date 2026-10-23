# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Seq do
  @moduledoc """
  Sequence maps: `%{actor_uri => non_neg_integer}`.

  This is the only place that decides "does the announced state differ
  from what I hold?". Both the notification path and the pull path go
  through `behind/2`, so the two cannot disagree.
  """

  @type t :: %{String.t() => non_neg_integer}

  @doc "Actors whose announced seq is ahead of ours (missing counts as 0)."
  @spec behind(t, t) :: t
  def behind(have, announced) do
    for {actor, seq} <- announced, seq > Map.get(have, actor, 0), into: %{}, do: {actor, seq}
  end

  @doc "Advance `have` to at least `seen`; never moves backwards."
  @spec merge(t, t) :: t
  def merge(have, seen), do: Map.merge(have, seen, fn _actor, a, b -> max(a, b) end)

  @doc "Shape check for untrusted input. Parsed once, at the edge."
  @spec parse(term) :: {:ok, t} | :error
  def parse(map) when is_map(map) and map_size(map) <= 1_000 do
    if Enum.all?(map, &valid_entry?/1), do: {:ok, map}, else: :error
  end

  def parse(_), do: :error

  defp valid_entry?({actor, seq}), do: is_binary(actor) and is_integer(seq) and seq >= 0
end
