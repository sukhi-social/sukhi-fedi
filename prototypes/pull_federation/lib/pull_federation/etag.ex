# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Etag do
  @moduledoc """
  The per-key token that stands for "the state of this actor's index
  right now". Two kinds, told apart by prefix, chosen by the origin:

    * `"s.<n>"`  **ordered**: the index's sequence number. Safe where the
      count is already public (the public index equals the public outbox).
      A receiver may compare two ordered tokens, so it can drop a stale
      notification without pulling, and the origin can answer a cursor
      exactly ("everything after n") with no replay.
    * `"o.<random>"` **opaque**: 12 random bytes drawn when the event is
      appended and stored on it. Nothing derived from the counter, no key
      to keep or rotate, says nothing about how many activities exist, and
      cannot be forged or predicted. Used where the count is not public
      (the followers-only index). Receivers can only test equality; the
      origin finds the token again among the events it holds.

  A timestamp would work as an ordered token too, but it is worse than the
  counter: it leaks when the actor is active, two events can share a
  millisecond, and a clock step backwards breaks the order. A counter
  assigned by the database has none of those problems.
  """

  @spec ordered(pos_integer) :: String.t()
  def ordered(seq), do: "s." <> Integer.to_string(seq)

  @spec opaque() :: String.t()
  def opaque, do: "o." <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))

  @doc "`:lt | :eq | :gt` for two ordered tokens, `:eq` for identical ones, else `:unordered`."
  @spec compare(String.t(), String.t()) :: :lt | :eq | :gt | :unordered
  def compare(same, same), do: :eq

  def compare("s." <> a, "s." <> b) do
    case {Integer.parse(a), Integer.parse(b)} do
      {{x, ""}, {y, ""}} when x < y -> :lt
      {{x, ""}, {y, ""}} when x > y -> :gt
      _ -> :unordered
    end
  end

  def compare(_, _), do: :unordered

  @doc "The sequence number inside an ordered token."
  @spec seq(String.t()) :: {:ok, non_neg_integer} | :error
  def seq("s." <> n) do
    case Integer.parse(n) do
      {x, ""} when x >= 0 -> {:ok, x}
      _ -> :error
    end
  end

  def seq(_), do: :error

  @doc "Shape check for untrusted tokens."
  @spec valid?(term) :: boolean
  def valid?("s." <> _ = t), do: byte_size(t) <= 24 and match?({:ok, _}, seq(t))
  def valid?("o." <> rest), do: byte_size(rest) in 1..62 and rest =~ ~r/\A[A-Za-z0-9_-]+\z/
  def valid?(_), do: false
end
