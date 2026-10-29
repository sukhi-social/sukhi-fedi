# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.TestMemBlobs do
  @moduledoc "An in-memory `SukhiFedi.RawStore.Backend` for tests (the Agent is passed as `:agent`)."

  @behaviour SukhiFedi.RawStore.Backend

  def put(k, b, o),
    do: Agent.update(o[:agent], &Map.put(&1, k, {b, o[:now] || System.os_time(:second)}))

  def get(k, o),
    do: with({b, _} <- Agent.get(o[:agent], &Map.get(&1, k)) || {:error, :missing}, do: {:ok, b})

  def exists?(k, o), do: Agent.get(o[:agent], &Map.has_key?(&1, k))
  def delete(k, o), do: Agent.update(o[:agent], &Map.delete(&1, k))

  def list_older_than(t, o),
    do: {:ok, Agent.get(o[:agent], fn m -> for {k, {_, at}} <- m, at <= t, do: k end)}
end
