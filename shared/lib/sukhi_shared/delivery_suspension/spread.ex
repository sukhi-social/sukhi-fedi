# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.Spread do
  @moduledoc """
  When to tell each peer, so that "we are back" (the cancellation) and
  "we are resting" (the Create) do not arrive as one wave (docs/DELIVERY_SUSPENSION.md).

  `schedule/2` takes the peers and returns `{peer, delay_ms}` pairs:

    * **random order** — a different peer is first each time, so nobody is
      always the one who hears last;
    * **a rate ceiling** — the time line is cut into slots of `1000 /
      per_second` ms and each peer gets exactly one slot, at a random point
      inside it. So in any window of one second at most `per_second + 1` are
      sent, however many peers there are;
    * the list is only a plan. The *concurrency* limit is the queue the jobs
      run in (its worker count), not something a list of delays can promise.

  Pure: it neither sends nor reads the clock.
  """

  @default_per_second 5

  @spec schedule([term()], keyword()) :: [{term(), non_neg_integer()}]
  def schedule(peers, opts \\ []) when is_list(peers) do
    per_second = max(Keyword.get(opts, :per_second, @default_per_second), 1)
    shuffle = Keyword.get(opts, :shuffle, &Enum.shuffle/1)
    jitter = Keyword.get(opts, :jitter, &:rand.uniform/1)

    slot = max(div(1000, per_second), 1)

    peers
    |> Enum.uniq()
    |> shuffle.()
    |> Enum.with_index()
    |> Enum.map(fn {peer, i} -> {peer, i * slot + jitter.(slot) - 1} end)
  end

  @doc "How long the whole plan takes, in milliseconds (the last delay)."
  @spec duration([{term(), non_neg_integer()}]) :: non_neg_integer()
  def duration([]), do: 0
  def duration(plan), do: plan |> Enum.map(&elem(&1, 1)) |> Enum.max()
end
