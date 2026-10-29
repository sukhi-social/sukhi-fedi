# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Admin do
  @moduledoc """
  Whole-database operations: emptying (tests), and a figure for the size.
  """

  alias SukhiFedi.Datalevin.{Catalog, Client, Edn, Engine}

  @doc "Remove every row of every table. Id counters are kept, as a sequence would be."
  @spec wipe!() :: :ok
  def wipe! do
    tables = Catalog.tables()

    queries =
      Enum.map(tables, fn t ->
        "[:find [?e ...] :where [?e #{Edn.literal(Engine.anchor_attr(t))} _]]"
      end)

    eids =
      queries
      |> then(&Client.query_many/1)
      |> Enum.flat_map(fn
        {:ok, es} when is_list(es) -> es
        {:ok, _} -> []
        {:error, e} -> raise "wipe failed: #{inspect(e)}"
      end)

    eids
    |> Enum.chunk_every(1000)
    |> Enum.each(fn chunk ->
      {:ok, _} = Client.transact(Enum.map(chunk, &[":db/retractEntity", &1]))
    end)

    :ok
  end
end
