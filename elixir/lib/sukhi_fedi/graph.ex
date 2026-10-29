# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph do
  @moduledoc """
  The graph store: actors, objects, activities and the edges between them,
  kept in Datalevin in the shape `priv/datalevin/schema.edn` describes
  (docs/DATALEVIN_SCHEMA.md). It is a second database beside the
  Ecto-compatible one (`<DATALEVIN_DIR>/graph`), with its own `dtlv` child.

  This module is the thin edge: run a query, run a transaction, serialise the
  read-then-write steps. What goes *in* is `SukhiFedi.Graph.Ingest`; what
  gets *rid* of is `SukhiFedi.Graph.Sweep`; the batch that fills the search
  text is `SukhiFedi.Graph.Tokens`.

  Times are microseconds since the Unix epoch (`:db.type/long`): the MCP
  JSON surface cannot write a Datalevin instant.
  """

  alias SukhiFedi.Datalevin.Client

  @client __MODULE__.Client

  @doc "Is the graph store running beside the main one? (`SUKHI_GRAPH=1`, read once into config by `runtime.exs`.)"
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:sukhi_fedi, :graph, false) == true

  @doc "Children for the application's supervisor: the graph's `dtlv` and the mirror queue; none when off."
  @spec children() :: [module()]
  def children, do: if(enabled?(), do: [__MODULE__.Supervisor, __MODULE__.Mirror], else: [])

  @doc "The name the graph's `dtlv` child is registered under."
  @spec client() :: atom()
  def client, do: @client

  @spec query(String.t()) :: {:ok, term()} | {:error, term()}
  def query(edn), do: Client.query(@client, edn)

  @doc "A query whose result is a relation; an error raises (callers are batch jobs and tests)."
  @spec query!(String.t()) :: [list()]
  def query!(edn) do
    case query(edn) do
      {:ok, rows} -> rows
      {:error, reason} -> raise "graph query failed: #{inspect(reason)}\n#{edn}"
    end
  end

  @spec transact([term()]) :: {:ok, map()} | {:error, term()}
  def transact(tx), do: Client.transact(@client, tx)

  @doc """
  Run `fun` as the only writer. Read-then-write steps (take a free `sid`,
  look up a thread's root, then write) must not interleave with another
  writer's. Not re-entrant: do not nest.
  """
  @spec exclusive((-> result)) :: result when result: term()
  def exclusive(fun) do
    :global.trans({{__MODULE__, :write}, self()}, fun, [node()], :infinity)
  end

  @doc "Wall clock as the store's time: microseconds since the epoch."
  @spec now() :: integer()
  def now, do: System.os_time(:microsecond)

  @doc "Anything time-like → microseconds; `nil` stays `nil`."
  @spec micros(DateTime.t() | String.t() | integer() | nil) :: integer() | nil
  def micros(nil), do: nil
  def micros(n) when is_integer(n), do: n
  def micros(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  def micros(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :microsecond)
      {:error, _} -> nil
    end
  end
end
