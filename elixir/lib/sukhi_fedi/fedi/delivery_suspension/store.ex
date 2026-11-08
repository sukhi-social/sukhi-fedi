# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Store do
  @moduledoc """
  What FEP-f799 remembers, in the graph store (`priv/datalevin/schema.edn`,
  the `dsnotice/` `dspending/` `dsevidence/` `dscutoff/` attributes). Four
  kinds of row, no refs:

    * **notices** — one per notice `id`. A cancelled row is kept as the
      mark that ends it: a later, higher `revision` does not bring it back.
    * **pending cancellations** — an `Undo` that arrived before the `Create`
      it undoes, held by `(actor, create_id)` until the `Create` shows up or
      the notice-age limit passes. Capped per actor and in all.
    * **control evidence** — the last time a controller's right to speak for
      a target was freshly confirmed (written by the control check, stage 4).
    * **controller cutoffs** — "nothing published before this is accepted
      from this controller". Forgetting a notice (`sweep/2`) advances it by
      as much, so loosening the age limit later cannot revive a cancelled
      notice we no longer remember.

  Reads never lock. A caller that reads and then writes does both inside
  `exclusive/1` (the graph's one writer), and never nests it; nothing here
  takes the lock itself.

  Times in rows are microseconds since the epoch; a `Notice`'s `DateTime`s
  travel as ISO 8601 inside the `record` JSON, which is the authority for
  reading a notice back (the other `dsnotice/` attributes are for indexes).
  """

  alias SukhiFedi.Datalevin.Edn
  alias SukhiFedi.Graph
  alias SukhiShared.DeliverySuspension.{Notice, Policy}

  @doc "Run `fun` as the only writer. Not re-entrant."
  @spec exclusive((-> result)) :: result when result: term()
  def exclusive(fun), do: Graph.exclusive(fun)

  # ── notices ──────────────────────────────────────────────────────────────

  @doc """
  The stored notice with this `id`, with the id of the `Create` that carried
  it (`nil` if it arrived as an `Update` first).
  """
  @spec get_notice(String.t()) :: {:ok, Notice.t(), String.t() | nil} | :none | {:error, term()}
  def get_notice(id) when is_binary(id) do
    read_one(
      "[:find ?r ?c :where [?e :dsnotice/id #{Edn.literal(id)}] [?e :dsnotice/record ?r]" <>
        " [(get-else $ ?e :dsnotice/create-id \"\") ?c]]"
    )
  end

  @doc "The notice that `actor`'s `Create` `create_id` carried, if we have it."
  @spec get_notice_by_create(String.t(), String.t()) ::
          {:ok, Notice.t(), String.t() | nil} | :none | {:error, term()}
  def get_notice_by_create(actor, create_id) when is_binary(actor) and is_binary(create_id) do
    read_one(
      "[:find ?r ?c :where [?e :dsnotice/controller #{Edn.literal(actor)}]" <>
        " [?e :dsnotice/create-id #{Edn.literal(create_id)}]" <>
        " [?e :dsnotice/record ?r] [(get-else $ ?e :dsnotice/create-id \"\") ?c]]"
    )
  end

  @doc "Every stored notice: what the cache is rebuilt from after a restart."
  @spec all_notices() :: {:ok, [Notice.t()]} | {:error, term()}
  def all_notices do
    with {:ok, rows} <- Graph.query("[:find ?r :where [?e :dsnotice/record ?r]]") do
      {:ok, for([r] <- rows, do: decode(r))}
    end
  end

  @doc "How many notices this controller has with us (cancelled ones count: they are marks)."
  @spec count_notices(String.t()) :: non_neg_integer()
  def count_notices(controller) when is_binary(controller) do
    count("[:find (count ?e) :where [?e :dsnotice/controller #{Edn.literal(controller)}]]")
  end

  @doc """
  Write `notice` (insert or replace by `id`). Options: `:create_id`, and
  `:snapshot`, the document as received.
  """
  @spec put_notice(Notice.t(), keyword()) :: :ok | {:error, term()}
  def put_notice(%Notice{} = n, opts \\ []) do
    row =
      %{
        ":db/id" => -1,
        ":dsnotice/id" => n.id,
        ":dsnotice/controller" => n.controller,
        ":dsnotice/target-kind" => ":#{n.target_kind}",
        ":dsnotice/target" => n.target,
        ":dsnotice/status" => ":#{n.status}",
        ":dsnotice/revision" => n.revision,
        ":dsnotice/published" => micros(n.published),
        ":dsnotice/record" => encode(n)
      }
      |> put_if(":dsnotice/create-id", opts[:create_id])
      |> put_if(":dsnotice/snapshot", opts[:snapshot])

    transact([row])
  end

  # ── pending cancellations ────────────────────────────────────────────────

  @doc """
  Hold an `Undo` whose `Create` has not arrived. `{:error, :full}` when
  the actor (or the table) is at its cap: the caller drops it, which only
  costs us a cancellation we would have had to fetch to believe anyway.
  """
  @spec put_pending(String.t(), String.t(), DateTime.t(), Policy.t()) ::
          :ok | {:error, :full | term()}
  def put_pending(actor, create_id, %DateTime{} = now, %Policy{} = policy) do
    cond do
      count("[:find (count ?e) :where [?e :dspending/actor #{Edn.literal(actor)}]]") >=
          policy.max_pending_per_actor ->
        {:error, :full}

      count("[:find (count ?e) :where [?e :dspending/actor _]]") >= policy.max_pending_total ->
        {:error, :full}

      true ->
        transact([
          %{
            ":db/id" => -1,
            ":dspending/actor" => actor,
            ":dspending/create-id" => create_id,
            ":dspending/received-at" => micros(now),
            ":dspending/expires-at" => micros(DateTime.add(now, policy.notice_max_age, :second))
          }
        ])
    end
  end

  @doc "Is an `Undo` held for this `(actor, create_id)` that has not expired?"
  @spec pending?(String.t(), String.t(), DateTime.t()) :: boolean()
  def pending?(actor, create_id, %DateTime{} = now) do
    count(
      "[:find (count ?e) :where [?e :dspending/actor #{Edn.literal(actor)}]" <>
        " [?e :dspending/create-id #{Edn.literal(create_id)}]" <>
        " [?e :dspending/expires-at ?x] [(> ?x #{micros(now)})]]"
    ) > 0
  end

  @doc "Drop the held `Undo` for `(actor, create_id)`, once it has been applied."
  @spec delete_pending(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_pending(actor, create_id) do
    case Graph.query(
           "[:find ?e :where [?e :dspending/actor #{Edn.literal(actor)}]" <>
             " [?e :dspending/create-id #{Edn.literal(create_id)}]]"
         ) do
      {:ok, rows} -> retract(for [e] <- rows, do: e)
      {:error, _} = error -> error
    end
  end

  # ── control evidence (stage 4 writes it; the row is here so the shape is one) ──

  @type evidence :: %{
          verified_at: DateTime.t() | nil,
          attempted_at: DateTime.t() | nil,
          failure: atom() | nil
        }

  @spec get_evidence(atom(), String.t(), String.t()) :: {:ok, evidence()} | :none
  def get_evidence(kind, target, controller) when is_atom(kind) do
    # Not `get-else`: dtlv answers a `get-else` query again from memory after
    # the value it read has been rewritten (seen with the row below: the second
    # attempt's `failure` did not show). Plain clauses are read each time, so
    # the row is read as (attribute, value) pairs and folded here.
    q =
      "[:find ?a ?v :where [?e :dsevidence/kind #{Edn.literal(kind)}]" <>
        " [?e :dsevidence/target #{Edn.literal(target)}]" <>
        " [?e :dsevidence/controller #{Edn.literal(controller)}]" <>
        " [?e ?a ?v]]"

    case Graph.query(q) do
      {:ok, [_ | _] = pairs} ->
        row = Map.new(pairs, fn [a, v] -> {a, v} end)

        {:ok,
         %{
           verified_at: from_micros(row[":dsevidence/verified-at"]),
           attempted_at: from_micros(row[":dsevidence/attempted-at"]),
           failure: failure(row[":dsevidence/failure"])
         }}

      _ ->
        :none
    end
  end

  @doc "Record an attempt: `verified_at` only moves when `attrs` has one."
  @spec put_evidence(atom(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_evidence(kind, target, controller, attrs) when is_atom(kind) do
    row =
      %{
        ":db/id" => -1,
        ":dsevidence/kind" => ":#{kind}",
        ":dsevidence/target" => target,
        ":dsevidence/controller" => controller
      }
      |> put_if(":dsevidence/verified-at", micros(attrs[:verified_at]))
      |> put_if(":dsevidence/attempted-at", micros(attrs[:attempted_at]))
      |> put_if(":dsevidence/failure", attrs[:failure] && ":#{attrs[:failure]}")

    transact([row])
  end

  # ── cutoffs ──────────────────────────────────────────────────────────────

  @doc "The controller's cutoff: notices published before it are not accepted. `nil` = none."
  @spec cutoff(String.t()) :: DateTime.t() | nil
  def cutoff(controller) when is_binary(controller) do
    case Graph.query(
           "[:find ?b :where [?e :dscutoff/controller #{Edn.literal(controller)}]" <>
             " [?e :dscutoff/before ?b]]"
         ) do
      {:ok, [[b] | _]} -> from_micros(b)
      _ -> nil
    end
  end

  @doc "Move the controller's cutoff forward to `at` (never back)."
  @spec advance_cutoff(String.t(), DateTime.t()) :: :ok | {:error, term()}
  def advance_cutoff(controller, %DateTime{} = at) do
    case cutoff(controller) do
      %DateTime{} = current ->
        if DateTime.compare(at, current) == :gt, do: write_cutoff(controller, at), else: :ok

      nil ->
        write_cutoff(controller, at)
    end
  end

  defp write_cutoff(controller, at) do
    transact([
      %{":db/id" => -1, ":dscutoff/controller" => controller, ":dscutoff/before" => micros(at)}
    ])
  end

  # ── forgetting ───────────────────────────────────────────────────────────

  @doc """
  Forget what can no longer be accepted anyway: notices published longer ago
  than the age limit, and held `Undo`s past their expiry. Each forgotten
  notice advances its controller's cutoff past its `published`, so the
  cancellation is remembered by the line even when the row is gone.
  Returns `%{notices: n, pending: m}`.
  """
  @spec sweep(DateTime.t(), Policy.t()) :: %{
          notices: non_neg_integer(),
          pending: non_neg_integer()
        }
  def sweep(%DateTime{} = now, %Policy{} = policy) do
    horizon = DateTime.add(now, -policy.notice_max_age, :second)

    old =
      case Graph.query(
             "[:find ?e ?c ?p :where [?e :dsnotice/published ?p] [(< ?p #{micros(horizon)})]" <>
               " [?e :dsnotice/controller ?c]]"
           ) do
        {:ok, rows} -> rows
        _ -> []
      end

    # Cutoffs first: if we stop between the two steps, the line is ahead of
    # the rows, which is the safe side.
    old
    |> Enum.group_by(fn [_e, c, _p] -> c end, fn [_e, _c, p] -> p end)
    |> Enum.each(fn {controller, published} ->
      # The first instant still acceptable: the forgotten notice's own
      # `published` must be refused too.
      _ = advance_cutoff(controller, from_micros(Enum.max(published) + 1))
    end)

    _ = retract(for [e, _c, _p] <- old, do: e)

    expired =
      case Graph.query("[:find ?e :where [?e :dspending/expires-at ?x] [(<= ?x #{micros(now)})]]") do
        {:ok, rows} -> for [e] <- rows, do: e
        _ -> []
      end

    _ = retract(expired)
    %{notices: length(old), pending: length(expired)}
  end

  # ── plumbing ─────────────────────────────────────────────────────────────

  defp read_one(edn) do
    case Graph.query(edn) do
      {:ok, [[record, create_id] | _]} ->
        {:ok, decode(record), if(create_id == "", do: nil, else: create_id)}

      {:ok, []} ->
        :none

      {:error, _} = error ->
        error
    end
  end

  defp count(edn) do
    case Graph.query(edn) do
      {:ok, [[n] | _]} when is_integer(n) -> n
      _ -> 0
    end
  end

  # A single write is its own whole step: the engine serialises writes. A
  # read-then-write step holds `exclusive/1` around its reads and its writes.
  defp transact(tx) do
    case Graph.transact(tx) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp retract([]), do: :ok

  defp retract(eids) do
    case Graph.transact(for(e <- eids, do: [":db.fn/retractEntity", e])) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp micros(nil), do: nil
  defp micros(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp from_micros(n) when is_integer(n) and n > 0, do: DateTime.from_unix!(n, :microsecond)
  defp from_micros(_), do: nil

  defp failure(":none"), do: nil
  defp failure(":" <> name), do: String.to_existing_atom(name)
  defp failure(_), do: nil

  # The record is the whole notice, times as ISO 8601 text.
  @times ~w(published start_time end_time effective_start proof_expires_at accepted_at cancelled_at)a

  defp encode(%Notice{} = n) do
    n
    |> Map.from_struct()
    |> Map.new(fn
      {k, %DateTime{} = v} when k in @times -> {k, DateTime.to_iso8601(v)}
      {k, v} when k in [:target_kind, :status] -> {k, Atom.to_string(v)}
      pair -> pair
    end)
    |> JSON.encode!()
  end

  defp decode(json) do
    map = JSON.decode!(json)

    fields =
      for {key, value} <- map, into: %{} do
        k = String.to_existing_atom(key)

        v =
          cond do
            k in @times and is_binary(value) ->
              {:ok, dt, _} = DateTime.from_iso8601(value)
              dt

            k in [:target_kind, :status] ->
              String.to_existing_atom(value)

            true ->
              value
          end

        {k, v}
      end

    struct!(Notice, fields)
  end
end
