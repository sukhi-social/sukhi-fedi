# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Migration.Ops do
  @moduledoc """
  The few things a migration does to data, written so that running one again
  over half-done work finishes it and changes nothing else
  (`SukhiFedi.Datalevin.Migration`, "The contract").

  Attributes are atoms (`:"accounts/locked"`). Every operation walks the
  matching entities a slice at a time and writes `DATALEVIN_BATCH` of them
  per transaction, so a table of millions of rows neither exceeds dtlv's
  result limit nor is held in memory whole.

  Writes go through `transact!/2` only: the migrator owns the store while a
  migration runs, so no writer lock is needed.
  """

  require Logger

  alias SukhiFedi.Datalevin.{Client, Edn}
  alias SukhiFedi.Datalevin.Migration.Ctx

  @type attr :: atom()

  @doc "Give `attr` the value `value` on every entity that has `anchor` and lacks `attr`. Returns how many it set."
  @spec backfill!(Ctx.t(), anchor :: attr(), attr(), term()) :: non_neg_integer()
  def backfill!(%Ctx{} = ctx, anchor, attr, value) when not is_nil(value) do
    # `not`, not `missing?`: dtlv's `missing?` also counts a stored `false`
    # as missing, and a boolean that is `false` is a value (CI showed it).
    where = "[?e #{lit(anchor)} _] (not [?e #{lit(attr)} _])"

    each_match(ctx, "[?e ...]", where, fn eids ->
      eids
      |> Enum.map(&[":db/add", &1, wire(attr), enc(value)])
      |> write!(ctx)

      length(eids)
    end)
    |> done(ctx, "backfill", attr)
  end

  @doc """
  Move the values of `old` to `new`, then remove `old`. Returns how many
  entities were moved. `new` must be defined (a new attribute in the current
  schema, or one this migration lists in `schema/0`).
  """
  @spec rename_attr!(Ctx.t(), old :: attr(), new :: attr()) :: non_neg_integer()
  def rename_attr!(%Ctx{} = ctx, old, new) do
    # Two walks, not one: an entity with several values (cardinality many)
    # can have them split across batches, and removing `old` after the first
    # batch would lose the rest. Copy everything, then remove. A stop in
    # between leaves both; the next run copies again (a same value is a
    # no-op) and then removes.
    each_match(ctx, "?e ?v", "[?e #{lit(old)} ?v]", fn rows ->
      rows |> Enum.map(fn [e, v] -> [":db/add", e, wire(new), enc(v)] end) |> write!(ctx)
      0
    end)

    each_match(ctx, "[?e ...]", "[?e #{lit(old)} _]", fn eids ->
      eids |> Enum.map(&[":db.fn/retractAttribute", &1, wire(old)]) |> write!(ctx)
      length(eids)
    end)
    |> done(ctx, "rename", {old, new})
  end

  @doc "Remove `attr` from every entity that has it. Returns how many entities."
  @spec retract_attr!(Ctx.t(), attr()) :: non_neg_integer()
  def retract_attr!(%Ctx{} = ctx, attr) do
    each_match(ctx, "[?e ...]", "[?e #{lit(attr)} _]", fn eids ->
      eids |> Enum.map(&[":db.fn/retractAttribute", &1, wire(attr)]) |> write!(ctx)
      length(eids)
    end)
    |> done(ctx, "retract", attr)
  end

  @doc "Remove every entity that has `anchor`: a table dropped. Returns how many."
  @spec drop_entities!(Ctx.t(), anchor :: attr()) :: non_neg_integer()
  def drop_entities!(%Ctx{} = ctx, anchor) do
    each_match(ctx, "[?e ...]", "[?e #{lit(anchor)} _]", fn eids ->
      eids |> Enum.map(&[":db/retractEntity", &1]) |> write!(ctx)
      length(eids)
    end)
    |> done(ctx, "drop", anchor)
  end

  @doc "A Datalog query (EDN text) against the store; raises on error."
  @spec query!(Ctx.t(), String.t()) :: term()
  def query!(%Ctx{client: client}, edn) do
    case Client.query(client, edn) do
      {:ok, result} -> result
      {:error, e} -> raise "datalevin migration query failed: #{inspect(e)}\n#{edn}"
    end
  end

  @doc "Transaction data against the store; raises on error."
  @spec transact!(Ctx.t(), [term()]) :: map()
  def transact!(%Ctx{client: client}, tx) do
    case Client.transact(client, tx) do
      {:ok, tempids} -> tempids
      {:error, e} -> raise "datalevin migration transaction failed: #{inspect(e)}"
    end
  end

  # ---------------------------------------------------------------- walking

  # Run `fun` on the matches of `[:find <find> :where <where>]`, a slice of
  # entity ids at a time. dtlv refuses an answer past its limit
  # (`:result-too-large`); a slice that is too big is halved. `fun` returns a
  # count; the sum is returned. Slices are disjoint ranges of entity ids, so
  # `fun` may remove what it was given without disturbing the walk.
  defp each_match(ctx, find, where, fun) do
    case Client.query(ctx.client, "[:find (max ?e) . :where #{where}]") do
      {:ok, max} when is_integer(max) -> walk(ctx, find, where, 0, max + 1, fun)
      {:ok, _none} -> 0
      {:error, e} -> raise "datalevin migration query failed: #{inspect(e)}"
    end
  end

  defp walk(ctx, find, where, lo, hi, fun) do
    q = "[:find #{find} :where #{where} [(>= ?e #{lo})] [(< ?e #{hi})]]"

    case Client.query(ctx.client, q) do
      {:ok, []} ->
        0

      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.chunk_every(ctx.config.batch)
        |> Enum.reduce(0, fn chunk, n -> n + fun.(chunk) end)

      {:error, %{"code" => ":result-too-large"}} when hi - lo > 1 ->
        mid = div(lo + hi, 2)
        walk(ctx, find, where, lo, mid, fun) + walk(ctx, find, where, mid, hi, fun)

      {:error, e} ->
        raise "datalevin migration query failed: #{inspect(e)}"
    end
  end

  defp write!([], _ctx), do: :ok

  defp write!(tx, ctx) do
    tx |> Enum.chunk_every(ctx.config.batch) |> Enum.each(&transact!(ctx, &1))
  end

  defp done(count, ctx, what, subject) do
    Logger.info(
      "datalevin_migration_op store=#{ctx.store} op=#{what} subject=#{inspect(subject)} entities=#{count}"
    )

    count
  end

  defp lit(attr) when is_atom(attr), do: Edn.literal(attr)
  defp wire(attr) when is_atom(attr), do: Edn.literal(attr)
  defp enc(i) when is_integer(i), do: Edn.encode_int(i)
  defp enc(v), do: v
end
