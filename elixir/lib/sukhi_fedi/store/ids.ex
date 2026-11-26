# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Store.Ids do
  @moduledoc """
  The layout of an id hosigraph hands out: `(unix_ms - epoch) <<< 21`, then a counter in the low
  21 bits. A larger id is a later write, so an id says when a row was written, and a time can be
  turned into an id that sorts with the real ones. (`SukhiFedi.Snowflake` is the older layout,
  epoch 2024 and 16 bits: ids of the two do not compare.)
  """

  import Bitwise

  # 2026-01-01T00:00:00Z
  @epoch_ms 1_767_225_600_000
  @counter_bits 21

  @doc "An id for the instant `unix_ms`, with `counter` in its low bits."
  def encode(unix_ms, counter) when is_integer(unix_ms) and is_integer(counter),
    do: bsl(max(unix_ms - @epoch_ms, 0), @counter_bits) ||| rem(counter, bsl(1, @counter_bits))

  @doc "The unix-millisecond instant an id was handed out."
  def to_unix_ms(id) when is_integer(id), do: bsr(id, @counter_bits) + @epoch_ms

  @doc "The `DateTime` (millisecond precision) an id was handed out."
  def to_datetime(id) when is_integer(id), do: DateTime.from_unix!(to_unix_ms(id), :millisecond)
end
