# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Writer do
  @moduledoc """
  Row writes, with the checks Postgres did for us.

  Datalevin has no unique indexes over several columns, no foreign keys and
  no column defaults. This module enforces the ones the SQL schema declared
  (read from `Catalog`) — in one place, inside the writer lock, so the rest
  of the code can trust a row that was accepted:

    * unique indexes, including partial ones and `lower(col)` keys, reported
      the way Ecto expects (`{:invalid, unique: "index_name"}`) so
      `unique_constraint/3` in changesets keeps working;
    * `ON CONFLICT` (`:nothing`, replace, update query);
    * column defaults: sequences, `snowflake_id()`, `now()`, literals;
    * `ON DELETE CASCADE` / `SET NULL`.

  Not enforced: foreign keys on insert, `NOT NULL`, check constraints.

  ## Transactions

  `Repo.transaction/1` runs the function holding the writer lock, writing
  through as it goes and remembering how to undo each write. A rollback or an
  exception replays the undo steps in reverse. So: no other writer sees a
  half-finished transaction's *effects change under it*, and a rollback leaves
  nothing behind — but a *reader* can see uncommitted writes, and a crash in
  the middle of a transaction leaves it partly applied (WAL replay restores
  each write, not the transaction). See docs/DATALEVIN.md.
  """

  alias SukhiFedi.Datalevin.{Catalog, Engine, Eval, Ids, Lock, Types}

  @undo_key {__MODULE__, :undo}

  # ---------------------------------------------------------- transactions

  @doc "Run `fun` as a transaction. Returns `{:ok, value}`; `{:error, value}` after `rollback/1`."
  @spec transaction((-> term())) :: {:ok, term()} | {:error, term()}
  def transaction(fun) do
    if Process.get(@undo_key) do
      # Nested: part of the outer transaction.
      run_nested(fun)
    else
      Lock.run(fn ->
        Process.put(@undo_key, [])

        try do
          {:ok, fun.()}
        catch
          :throw, {__MODULE__, :rollback, value} ->
            undo_all()
            {:error, value}

          kind, reason ->
            undo_all()
            :erlang.raise(kind, reason, __STACKTRACE__)
        after
          Process.delete(@undo_key)
        end
      end)
    end
  end

  @doc "Run `fun` inside a transaction, starting one only if none is open; returns its value."
  @spec transaction_if_needed((-> result)) :: result when result: term()
  def transaction_if_needed(fun) do
    if in_transaction?() do
      fun.()
    else
      {:ok, v} = transaction(fun)
      v
    end
  end

  defp run_nested(fun) do
    {:ok, fun.()}
  catch
    :throw, {__MODULE__, :rollback, value} -> {:error, value}
  end

  @spec rollback(term()) :: no_return()
  def rollback(value), do: throw({__MODULE__, :rollback, value})

  @spec in_transaction?() :: boolean()
  def in_transaction?, do: Process.get(@undo_key) != nil

  defp undo_all do
    for undo <- Process.get(@undo_key, []), undo != [] do
      case Engine.transact(undo) do
        {:ok, _} -> :ok
        {:error, e} -> raise "datalevin rollback failed: #{inspect(e)}"
      end
    end

    Process.put(@undo_key, [])
  end

  defp commit(tx, undo) do
    case Engine.transact(tx) do
      {:ok, tempids} ->
        if (u = Process.get(@undo_key)) != nil, do: Process.put(@undo_key, [undo.(tempids) | u])
        {:ok, tempids}

      {:error, e} ->
        raise "datalevin write failed: #{inspect(e)}"
    end
  end

  # ----------------------------------------------------------------- insert

  @doc """
  Insert one row. `params` are stored values by column. Returns
  `{:ok, returning}`, `{:invalid, constraints}`; a skipped `:nothing` is `{:ok, []}`.
  """
  @spec insert(String.t(), keyword(), term(), [atom()]) ::
          {:ok, keyword()} | {:invalid, keyword()}
  def insert(table, params, on_conflict, returning) do
    Lock.run(fn -> insert_locked(table, params, on_conflict, returning) end)
  end

  defp insert_locked(table, params, {kind, conflict_params, target}, returning) do
    t = Catalog.table!(table)
    {row, seq_txs} = with_defaults(table, t, Map.new(params))
    conflicts = conflicts(table, t, row, nil)

    case {conflicts, kind} do
      {[], _} ->
        do_insert(table, row, seq_txs, returning)

      {[{name, _, _} | _], :raise} ->
        {:invalid, [unique: name]}

      {cs, :nothing} ->
        case relevant(cs, t, target) do
          [] when cs != [] and target != [] ->
            {:invalid, [unique: elem(hd(cs), 0)]}

          _ ->
            {:ok, []}
        end

      {cs, update} ->
        case relevant(cs, t, target) do
          [] ->
            {:invalid, [unique: elem(hd(cs), 0)]}

          [{_, eid, old} | _] ->
            new = on_conflict_row(update, conflict_params, old, row, params)
            update_row(table, t, eid, old, new, returning)
        end
    end
  end

  # `conflict_target: {:unsafe_fragment, "(a, b) WHERE ..."}` names its columns
  # in the leading parentheses.
  defp target_columns({:unsafe_fragment, sql}) do
    [_, cols] = Regex.run(~r/^\s*\(([^)]*)\)/, sql)
    cols |> String.split(",") |> Enum.map(&String.trim/1)
  end

  defp target_columns(cols) when is_list(cols), do: cols

  # Conflicts on the named target columns (all conflicts when no target).
  defp relevant(cs, _t, []), do: cs

  defp relevant(cs, t, target) do
    want = target |> target_columns() |> Enum.map(&to_string/1) |> Enum.sort()

    Enum.filter(cs, fn {name, _, _} ->
      cols =
        case name do
          n when is_binary(n) ->
            case Enum.find(t.unique, &(&1.name == n)) do
              nil -> t.pk
              u -> for {:col, c} <- u.keys, do: c
            end
        end

      Enum.sort(cols) == want
    end)
  end

  defp on_conflict_row(fields, _cp, old, new, _params) when is_list(fields) do
    Enum.reduce(fields, old, fn f, acc -> Map.put(acc, f, Map.get(new, f)) end)
  end

  defp on_conflict_row(%Ecto.Query{} = q, cp, old, new, params) do
    # `set:` expressions see the existing row as binding 0; their `^` indices
    # continue after the values of the insert itself.
    env = %{rows: {old}, params: Keyword.values(params) ++ cp, group: nil}
    _ = new

    Enum.reduce(q.updates, old, fn %{expr: kw}, acc ->
      Enum.reduce(kw, acc, fn
        {:set, sets}, a ->
          Enum.reduce(sets, a, fn {f, e}, aa -> Map.put(aa, f, Eval.eval(e, env)) end)

        {:inc, incs}, a ->
          Enum.reduce(incs, a, fn {f, e}, aa ->
            Map.put(aa, f, (Map.get(aa, f) || 0) + Eval.eval(e, env))
          end)
      end)
    end)
  end

  defp do_insert(table, row, seq_txs, returning) do
    ent = Engine.entity(table, row, -1)

    {:ok, _} =
      commit([ent | seq_txs], fn tempids ->
        [[":db/retractEntity", Map.fetch!(tempids, -1)]]
      end)

    {:ok, Enum.map(returning, &{&1, Map.get(row, &1)})}
  end

  # Defaults for the columns the caller did not mention.
  defp with_defaults(table, t, row) do
    Enum.reduce(t.columns, {row, []}, fn c, {r, seqs} ->
      key = String.to_atom(c.name)

      with false <- Map.has_key?(r, key), d when is_binary(d) <- c.default do
        case Types.default(d) do
          :sequence ->
            {n, seq} = Ids.next("#{table}.#{c.name}")
            {Map.put(r, key, n), [seq | seqs]}

          :snowflake ->
            {Map.put(r, key, Ids.snowflake()), seqs}

          :now ->
            {Map.put(r, key, System.os_time(:microsecond)), seqs}

          {:value, v} ->
            {Map.put(r, key, coerce(v, c.type)), seqs}

          :none ->
            {r, seqs}
        end
      else
        _ -> {r, seqs}
      end
    end)
  end

  defp coerce(v, "double precision") when is_integer(v), do: v * 1.0
  defp coerce(v, _), do: v

  # ----------------------------------------------------------------- update

  @doc "Update the row matching `filters`. `{:error, :stale}` if there is none."
  @spec update(String.t(), keyword(), keyword(), [atom()]) ::
          {:ok, keyword()} | {:invalid, keyword()} | {:error, :stale}
  def update(table, fields, filters, returning) do
    Lock.run(fn ->
      t = Catalog.table!(table)

      case Engine.fetch(table, filter_pds(filters)) do
        [] ->
          {:error, :stale}

        [{eid, old} | _] ->
          update_row(table, t, eid, old, Map.merge(old, Map.new(fields)), returning)
      end
    end)
  end

  @doc false
  def update_row(table, t, eid, old, new, returning) do
    case conflicts(table, t, new, eid) do
      [{name, _, _} | _] ->
        {:invalid, [unique: name]}

      [] ->
        {do_tx, undo_tx} = Engine.diff(table, eid, old, new)

        if do_tx != [],
          do: {:ok, _} = commit(Enum.reverse(do_tx), fn _ -> Enum.reverse(undo_tx) end)

        {:ok, Enum.map(returning, &{&1, Map.get(new, &1)})}
    end
  end

  @doc "Apply `new` over a row already fetched (for `update_all`); unique-checked."
  def replace(table, eid, old, new) do
    case update_row(table, Catalog.table!(table), eid, old, new, []) do
      {:ok, _} -> :ok
      {:invalid, c} -> {:invalid, c}
    end
  end

  # ----------------------------------------------------------------- delete

  @doc "Delete the row matching `filters`."
  @spec delete(String.t(), keyword(), [atom()]) ::
          {:ok, keyword()} | {:invalid, keyword()} | {:error, :stale}
  def delete(table, filters, returning) do
    Lock.run(fn ->
      case Engine.fetch(table, filter_pds(filters)) do
        [] ->
          {:error, :stale}

        [{eid, old} | _] ->
          case delete_row(table, eid, old) do
            :ok -> {:ok, Enum.map(returning, &{&1, Map.get(old, &1)})}
            {:invalid, _} = e -> e
          end
      end
    end)
  end

  @doc "Delete a fetched row, following `ON DELETE` of the foreign keys that point at it."
  @spec delete_row(String.t(), integer(), Engine.row()) :: :ok | {:invalid, keyword()}
  def delete_row(table, eid, old) do
    Lock.run(fn ->
      refs = Catalog.referencing(table)

      children =
        refs
        |> Enum.map(fn {child, fk} -> {child, fk, fk_pds(fk, old)} end)
        |> Enum.reject(fn {_, _, pds} -> pds == nil end)

      found = Engine.fetch_many(Enum.map(children, fn {c, _, pds} -> {c, pds} end))

      blocked =
        Enum.zip(children, found)
        |> Enum.find(fn {{_, fk, _}, rows} ->
          rows != [] and fk.on_delete in [:restrict, :none]
        end)

      case blocked do
        {{_, fk, _}, _} ->
          {:invalid, [foreign_key: fk.name]}

        nil ->
          for {{child, fk, _}, rows} <- Enum.zip(children, found), {ceid, crow} <- rows do
            case fk.on_delete do
              :cascade ->
                :ok = delete_row(child, ceid, crow)

              :nilify ->
                new = Enum.reduce(fk.columns, crow, &Map.put(&2, String.to_atom(&1), nil))
                {:ok, _} = update_row(child, Catalog.table!(child), ceid, crow, new, [])

              _ ->
                :ok
            end
          end

          {:ok, _} =
            commit([[":db/retractEntity", eid]], fn _ ->
              [Engine.entity(table, old, -1)]
            end)

          :ok
      end
    end)
  end

  defp fk_pds(fk, parent) do
    pds =
      Enum.zip(fk.columns, fk.ref_columns)
      |> Enum.map(fn {c, rc} ->
        case Map.get(parent, String.to_atom(rc)) do
          nil -> nil
          v -> {:eq, String.to_atom(c), v}
        end
      end)

    if Enum.any?(pds, &is_nil/1), do: nil, else: pds
  end

  # ----------------------------------------------------------- uniqueness

  @doc """
  Unique indexes `row` would violate: `[{index_name, eid, existing_row}]`.
  Primary key included. `exclude` is the entity being updated.
  """
  @spec conflicts(String.t(), Catalog.table(), Engine.row(), integer() | nil) ::
          [{String.t(), integer(), Engine.row()}]
  def conflicts(table, t, row, exclude) do
    indexes =
      [%{name: "#{table}_pkey", keys: Enum.map(t.pk, &{:col, &1}), where: []} | t.unique]
      |> Enum.filter(&applies?(&1, row))

    specs = Enum.map(indexes, fn idx -> {table, key_pds(idx, row)} end)

    Enum.zip(indexes, Engine.fetch_many(specs))
    |> Enum.flat_map(fn {idx, found} ->
      for {eid, existing} <- found,
          eid != exclude,
          same_key?(idx, row, existing),
          holds?(idx.where, existing),
          do: {idx.name, eid, existing}
    end)
  end

  defp applies?(%{keys: []}, _), do: false

  defp applies?(idx, row) do
    holds?(idx.where, row) and
      Enum.all?(idx.keys, fn
        {:col, c} -> Map.get(row, String.to_atom(c)) != nil
        {:lower, c} -> Map.get(row, String.to_atom(c)) != nil
        {:unsupported, _} -> false
      end)
  end

  defp holds?(where, row) do
    Enum.all?(where, fn
      {:null, c} -> Map.get(row, String.to_atom(c)) == nil
      {:not_null, c} -> Map.get(row, String.to_atom(c)) != nil
      {:unsupported, _} -> true
    end)
  end

  defp key_pds(idx, row) do
    for key <- idx.keys do
      case key do
        {:col, c} -> {:eq, String.to_atom(c), Map.fetch!(row, String.to_atom(c))}
        {:lower, c} -> {:notnull, String.to_atom(c)}
      end
    end
  end

  defp same_key?(idx, row, existing) do
    Enum.all?(idx.keys, fn
      {:col, c} ->
        Map.get(row, String.to_atom(c)) == Map.get(existing, String.to_atom(c))

      {:lower, c} ->
        lower(Map.get(row, String.to_atom(c))) == lower(Map.get(existing, String.to_atom(c)))
    end)
  end

  defp lower(v) when is_binary(v), do: String.downcase(v)
  defp lower(v), do: v

  defp filter_pds(filters) do
    Enum.map(filters, fn
      {k, nil} -> {:null, k}
      {k, v} -> {:eq, k, v}
    end)
  end
end
