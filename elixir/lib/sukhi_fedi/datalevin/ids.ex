# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Ids do
  @moduledoc """
  Where generated ids come from, in place of Postgres sequences and
  `snowflake_id()`.

  A sequence is a counter per `table.column`, kept in memory and written into
  the same transaction as the row that used it (`:seq/table`, `:seq/next`), so
  a restart continues after the highest id ever handed out. Like a Postgres
  sequence it never goes back: a rolled-back transaction leaves a gap.

  Callers hold `Lock` while they take an id.
  """

  alias SukhiFedi.Datalevin.Client
  alias SukhiFedi.Snowflake

  @table :sukhi_datalevin_ids

  def start_link(_) do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :public, :set])
    :ignore
  end

  @doc "Next value of the sequence `key` (`\"accounts.id\"`) and the tx-data that persists it."
  @spec next(String.t()) :: {integer(), map()}
  def next(key) do
    n =
      case :ets.lookup(@table, key) do
        [{_, n}] -> n
        [] -> load(key)
      end

    :ets.insert(@table, {key, n + 1})
    {n, %{":seq/table" => key, ":seq/next" => n + 1}}
  end

  # Continue after the persisted counter, or — for a database that came from
  # an import rather than from this store — after the highest id present.
  defp load(key) do
    q =
      ~s([:find ?n . :where [?s :seq/table #{SukhiFedi.Datalevin.Edn.literal(key)}] [?s :seq/next ?n]])

    case Client.query(q) do
      {:ok, n} when is_integer(n) ->
        n

      _ ->
        [table, column] = String.split(key, ".", parts: 2)
        attr = SukhiFedi.Datalevin.Catalog.attr(table, column)

        case Client.query(
               "[:find (max ?v) . :where [_ #{SukhiFedi.Datalevin.Edn.literal(attr)} ?v]]"
             ) do
          {:ok, m} when is_integer(m) -> m + 1
          _ -> 1
        end
    end
  end

  @doc "Make a note-style id for `now`, like the SQL `snowflake_id()`."
  @spec snowflake() :: integer()
  def snowflake do
    ms = System.os_time(:millisecond)
    Snowflake.encode(ms, :erlang.unique_integer([:positive]) |> rem(0x10000))
  end

  @doc """
  A note-style id for a remote note, minted from its `created_at` (stored
  microseconds) rather than the insert clock — the `set_remote_note_id`
  trigger's job on Postgres. A back-filled post is inserted now but was
  authored earlier; its id must sort where it was authored.
  """
  @spec snowflake_at(integer()) :: integer()
  def snowflake_at(created_at_us) when is_integer(created_at_us) do
    ms = div(created_at_us, 1000)
    Snowflake.encode(ms, :erlang.unique_integer([:positive]) |> rem(0x10000))
  end

  @doc "Forget the in-memory counters (tests that wipe the database)."
  def reset, do: :ets.delete_all_objects(@table)
end
