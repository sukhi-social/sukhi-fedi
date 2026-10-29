# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Mirror do
  @moduledoc """
  Copies each admitted inbound activity into the graph, after the usual
  path has run. The door (`SukhiFedi.AP.Ingest`) has already applied instance
  policy, the FEP-8b32 check and the executor; this is a side copy and
  **never** changes what the door answers.

    * One process, one mailbox: activities are written in the order they were
      admitted (a `Create` before its `Update`). Past `@max_backlog` waiting
      activities new ones are dropped with a warning: the mirror is
      best-effort until the graph is the store of record, and a backfill can
      close the gap; the inbox must not grow a queue without bound.
    * An embedded object whose id is not on the actor's own host is skipped
      unless the activity's author signed it (FEP-8b32): the same
      same-origin rule the executor applies, so a forged embedded object is
      not copied into the graph.
    * Any failure is logged and swallowed.
  """

  use GenServer

  require Logger

  alias SukhiFedi.Graph.Activity

  @max_backlog 10_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Queue `raw_json` for the graph. `opts`: `:raw_body` (the bytes received;
  re-encoded from the JSON when absent), `:author_signed?`.
  """
  @spec admit(map(), keyword()) :: :ok
  def admit(raw_json, opts \\ []) when is_map(raw_json) do
    if backlog() >= @max_backlog do
      Logger.warning("graph mirror: backlog full, dropped #{inspect(raw_json["id"])}")
    else
      GenServer.cast(__MODULE__, {:admit, raw_json, opts})
    end

    :ok
  end

  @doc "Do the work now, in the caller (what the server does per message; tests call it)."
  @spec record(map(), keyword()) :: Activity.result() | {:ignored, :cross_origin}
  def record(raw_json, opts \\ []) do
    if same_origin?(raw_json, Keyword.get(opts, :author_signed?, false)) do
      raw =
        Keyword.get_lazy(opts, :raw_body, fn ->
          raw_json |> :json.encode() |> IO.iodata_to_binary()
        end)

      Activity.record(raw_json, Keyword.merge(opts, raw: raw))
    else
      {:ignored, :cross_origin}
    end
  end

  # An embedded object (or actor document) must live where its actor does.
  @doc false
  @spec same_origin?(map(), boolean()) :: boolean()
  def same_origin?(%{"actor" => actor, "object" => %{"id" => id}}, false) when is_binary(id),
    do: host(actor) != nil and host(actor) == host(id)

  def same_origin?(_, _), do: true

  defp host(%{"id" => id}), do: host(id)
  defp host(uri) when is_binary(uri), do: URI.parse(uri).host
  defp host(_), do: nil

  defp backlog do
    case Process.whereis(__MODULE__) do
      nil -> 0
      pid -> Process.info(pid, :message_queue_len) |> elem(1)
    end
  end

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_cast({:admit, raw_json, opts}, state) do
    try do
      case record(raw_json, opts) do
        {:error, reason} ->
          Logger.warning("graph mirror: #{inspect(raw_json["id"])}: #{inspect(reason)}")

        _ ->
          :ok
      end
    rescue
      e ->
        Logger.warning("graph mirror: #{inspect(raw_json["id"])} raised #{Exception.message(e)}")
    catch
      kind, reason ->
        Logger.warning("graph mirror: #{inspect(raw_json["id"])} #{kind} #{inspect(reason)}")
    end

    {:noreply, state}
  end
end
