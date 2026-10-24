# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PullFederation.Gate do
  @moduledoc """
  Backpressure for serving pulls: at most `max/0` pull requests are being
  answered at once; the next gets `429` with a `Retry-After` and comes back
  later. This is the origin's way of saying "I am busy" without anyone
  queueing on us — the requester already holds the work and decides when to
  retry (docs/PULL_FEDERATION.md §6).

  The count is one atomic ETS counter, so admitting a request costs one
  `update_counter` and releasing it another, no process in the middle. The
  slot is released in an `after`, so a crash cannot leak one.
  """

  @table :sukhi_pull_gate
  @default_max 16

  @doc "Create the counter table. Idempotent; called at boot."
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
      :ets.insert(@table, {:in_flight, 0})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def max,
    do:
      Application.get_env(:sukhi_fedi, :pull_federation, [])
      |> Keyword.get(:max_streams, @default_max)

  @doc "How many requests are being answered right now."
  def in_flight do
    case :ets.lookup(@table, :in_flight) do
      [{_, n}] -> n
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc """
  Run `fun` in a slot, or return `{:busy, retry_after_seconds}` without
  running it. The retry hint is jittered so refused requesters do not all
  come back on the same second.
  """
  @spec with_slot((-> result)) :: result | {:busy, pos_integer()} when result: term()
  def with_slot(fun) do
    init()

    if :ets.update_counter(@table, :in_flight, 1) > max() do
      :ets.update_counter(@table, :in_flight, -1)
      {:busy, 1 + :rand.uniform(3)}
    else
      try do
        fun.()
      after
        :ets.update_counter(@table, :in_flight, -1)
      end
    end
  end
end
