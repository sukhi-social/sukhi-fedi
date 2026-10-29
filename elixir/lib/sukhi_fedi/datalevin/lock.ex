# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Lock do
  @moduledoc """
  The one writer.

  LMDB admits a single writer, and the store's read-then-write steps (check a
  unique index, take an id, write) must not interleave with another writer's.
  `run/1` holds this lock around such a step; `Repo.transaction/1` holds it for
  the whole transaction. It is re-entrant for the process that holds it, and
  released if that process dies. Plain reads never take it.
  """

  use GenServer

  @key {__MODULE__, :held}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Run `fun` while holding the writer lock (re-entrant)."
  @spec run((-> result)) :: result when result: term()
  def run(fun) do
    if Process.get(@key) do
      fun.()
    else
      :ok = GenServer.call(__MODULE__, :acquire, :infinity)
      Process.put(@key, true)

      try do
        fun.()
      after
        Process.delete(@key)
        GenServer.cast(__MODULE__, {:release, self()})
      end
    end
  end

  @doc "Does the calling process hold the lock?"
  @spec held?() :: boolean()
  def held?, do: Process.get(@key) == true

  @impl true
  def init(_), do: {:ok, %{holder: nil, ref: nil, queue: :queue.new()}}

  @impl true
  def handle_call(:acquire, {pid, _} = from, %{holder: nil} = s) do
    {:reply, :ok, grant(s, pid, from)}
  end

  def handle_call(:acquire, from, s), do: {:noreply, %{s | queue: :queue.in(from, s.queue)}}

  @impl true
  def handle_cast({:release, pid}, %{holder: pid} = s), do: {:noreply, next(s)}
  def handle_cast({:release, _}, s), do: {:noreply, s}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{ref: ref} = s), do: {:noreply, next(s)}
  def handle_info({:DOWN, _, :process, _, _}, s), do: {:noreply, s}

  defp grant(s, pid, _from), do: %{s | holder: pid, ref: Process.monitor(pid)}

  defp next(s) do
    if s.ref, do: Process.demonitor(s.ref, [:flush])
    s = %{s | holder: nil, ref: nil}

    case :queue.out(s.queue) do
      {{:value, {pid, _} = from}, q} ->
        GenServer.reply(from, :ok)
        grant(%{s | queue: q}, pid, from)

      {:empty, _} ->
        s
    end
  end
end
