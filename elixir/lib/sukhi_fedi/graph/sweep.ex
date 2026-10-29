# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Sweep do
  @moduledoc """
  Capacity cleanup of *remote* objects (docs/DATALEVIN_SCHEMA.md, "掃除").

  Never touched: remote actors and keys, local objects and activities,
  follow/block/mute edges, Tombstones. A remote object is **kept** if any of
  these holds; the reasons are derived here, from the graph, each time, and
  are not stored (a stored flag has to be taken off again on unpin/undo, and
  forgetting leaves something that can never be swept):

    * `:local_thread`  — a local object is in its thread (the whole thread stays)
    * `:young_thread`  — some object of its thread is still inside the TTL
    * `:local_touch`   — a local actor liked/reacted/boosted/bookmarked/pinned/
      voted on it, was mentioned in it, quoted it, or has a notification or report about it
    * `:followed`      — its author is followed by a local actor and it is
      inside the longer TTL

  Candidates are found by index (received-at older than the shorter TTL, not
  touched since); the keep rules then run **once per batch** on those, in one
  round trip. What is left, and everything that hangs off it, goes in one
  transaction. `run(:dry_run)` reports the same breakdown and changes nothing.

  Options: `:now` (µs), `:ttl_followed_s` (default 90 days), `:ttl_other_s`
  (14 days), `:limit` (candidates per run, default 2000).
  """

  alias SukhiFedi.{Graph, RawStore}
  alias SukhiFedi.Datalevin.Client

  @day 86_400
  # Candidates judged (and deleted) per round trip.
  @page 400

  # Entities that exist *for* an object and point at their owner: when the
  # owner goes, they go. The list is complete by test: every ref attribute of
  # the schema is here or in `@edges`, so a new one forces a decision.
  @dependents ~w(content/object attachment/object tagging/object reaction/object entry/object
                 activity/object notification/source poll/object choice/poll vote/choice
                 bookmark/object pin/object report/object)a

  # Ref attributes that describe an object (or someone else) and are not owned by it.
  @edges ~w(key/actor collection/owner object/attributed-to object/in-reply-to object/root
            object/quote-of object/to object/cc object/mentions object/emojis object/proof-key
            activity/actor follow/follower follow/followee follow/activity reaction/actor
            reaction/emoji notification/recipient notification/from bookmark/actor pin/actor
            list/owner list/members block/actor block/target mute/actor mute/target
            vote/actor report/actor user/actor entry/owner entry/via)a

  @spec classified_refs() :: {[atom()], [atom()]}
  def classified_refs, do: {@dependents, @edges}

  @type mode :: :dry_run | :execute

  @spec run(mode(), keyword()) :: map()
  def run(mode \\ :dry_run, opts \\ []) when mode in [:dry_run, :execute] do
    now = Keyword.get_lazy(opts, :now, &Graph.now/0)
    ttl_followed = Keyword.get(opts, :ttl_followed_s, 90 * @day)
    ttl_other = Keyword.get(opts, :ttl_other_s, 14 * @day)
    limit = Keyword.get(opts, :limit, 2000)
    cutoff_other = now - ttl_other * 1_000_000
    cutoff_followed = now - ttl_followed * 1_000_000

    scan = scan(mode, cutoff_other, cutoff_followed, limit)

    report = %{
      mode: mode,
      candidates: scan.examined,
      kept: Map.new(scan.kept, fn {reason, eids} -> {reason, length(eids)} end),
      delete: scan.doomed,
      dependents: scan.dependents
    }

    if mode == :execute and scan.doomed > 0,
      do: Map.put(report, :deleted, scan.doomed),
      else: report
  end

  @doc """
  Delete the blobs nothing points at (and past the grace period). Asks the
  graph about each blob one by one: listing every referenced blob would be
  unbounded, and a wrong "unreferenced" would lose an original.
  """
  @spec gc(RawStore.Config.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def gc(config \\ RawStore.Config.current()), do: RawStore.gc(&referenced?/1, config)

  @spec referenced?(String.t()) :: boolean()
  def referenced?(ref) do
    lit = SukhiFedi.Datalevin.Edn.literal(ref)

    Enum.any?(~w(object actor activity), fn ns ->
      Graph.query!("[:find ?e :where [?e :#{ns}/raw-ref #{lit}]]") != []
    end)
  end

  # ------------------------------------------------------------ candidates

  # The engine caps one answer at 10 000 items and a transaction at about as
  # many datoms, so the sweep walks the candidates oldest first in pages and
  # judges (and, on `:execute`, deletes) each page on its own. A page that is
  # all kept does not stall the run: the next page starts after it.
  defp scan(mode, cutoff_other, cutoff_followed, limit) do
    scan_page(
      %{examined: 0, kept: %{}, doomed: 0, dependents: 0, after: 0, seen: MapSet.new()},
      mode,
      cutoff_other,
      cutoff_followed,
      limit
    )
  end

  defp scan_page(%{examined: n} = acc, _, _, _, limit) when n >= limit, do: acc

  defp scan_page(acc, mode, cutoff_other, cutoff_followed, limit) do
    want = min(@page, limit - acc.examined)
    page = candidates(cutoff_other, acc.after, want + MapSet.size(acc.seen))
    fresh = Enum.reject(page, fn [o, _] -> MapSet.member?(acc.seen, o) end) |> Enum.take(want)

    if fresh == [] do
      acc
    else
      eids = Enum.map(fresh, fn [o, _] -> o end)
      kept = kept(eids, cutoff_other, cutoff_followed)
      doomed = eids -- (kept |> Map.values() |> Enum.concat() |> Enum.uniq())
      children = children(doomed)
      if mode == :execute, do: delete(children ++ doomed)

      [_, last] = List.last(fresh) |> then(fn [o, r] -> [o, r] end)
      at_last = for [o, r] <- fresh, r == last, do: o

      seen =
        if last == acc.after,
          do: MapSet.union(acc.seen, MapSet.new(at_last)),
          else: MapSet.new(at_last)

      acc = %{
        acc
        | examined: acc.examined + length(eids),
          kept: Map.merge(acc.kept, kept, fn _, a, b -> Enum.uniq(a ++ b) end),
          doomed: acc.doomed + length(doomed),
          dependents: acc.dependents + length(children),
          after: last,
          seen: seen
      }

      if length(fresh) < want,
        do: acc,
        else: scan_page(acc, mode, cutoff_other, cutoff_followed, limit)
    end
  end

  defp delete(eids) do
    eids
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      {:ok, _} = Graph.transact(for e <- chunk, do: [":db.fn/retractEntity", e])
    end)
  end

  # `[[eid, received-at], …]` oldest first, from `after` on (inclusive: several
  # objects can share a microsecond, the caller drops the ones it has seen).
  defp candidates(cutoff, after_r, take) do
    Graph.query!("""
    [:find ?r ?o :where [?o :object/local? false] [?o :object/received-at ?r]
                        [(>= ?r #{after_r})] [(< ?r #{cutoff})]
                        (not [?o :object/deleted-at _])
                        (not-join [?o] [?o :object/touched-at ?t] [(>= ?t #{cutoff})])
     :order-by [?r :asc] :limit #{take}]
    """)
    |> Enum.map(fn [r, o] -> [o, r] end)
  end

  # reason => eids (among the candidates) that must stay. One round trip.
  defp kept([], _, _), do: %{}

  defp kept(candidates, cutoff_other, cutoff_followed) do
    pool = "[(ground [#{Enum.join(candidates, " ")}]) [?o ...]]"

    rules = [
      local_thread: "#{pool} [?o :object/root ?r] [?x :object/root ?r] [?x :object/local? true]",
      young_thread:
        "#{pool} [?o :object/root ?r] [?x :object/root ?r] [?x :object/received-at ?t] [(>= ?t #{cutoff_other})]",
      young_thread:
        "#{pool} [?o :object/root ?r] [?x :object/root ?r] [?x :object/touched-at ?t] [(>= ?t #{cutoff_other})]",
      local_touch:
        "#{pool} [?a :activity/object ?o] [?a :activity/actor ?u] [?u :actor/local? true]",
      local_touch: "#{pool} [?b :bookmark/object ?o]",
      local_touch: "#{pool} [?b :pin/object ?o]",
      local_touch:
        "#{pool} [?x :reaction/object ?o] [?x :reaction/actor ?u] [?u :actor/local? true]",
      local_touch:
        "#{pool} [?p :poll/object ?o] [?c :choice/poll ?p] [?v :vote/choice ?c] [?v :vote/actor ?u] [?u :actor/local? true]",
      local_touch: "#{pool} [?o :object/mentions ?u] [?u :actor/local? true]",
      local_touch: "#{pool} [?q :object/quote-of ?o] [?q :object/local? true]",
      local_touch: "#{pool} [?n :notification/source ?o]",
      local_touch: "#{pool} [?r :report/object ?o]",
      followed:
        "#{pool} [?o :object/attributed-to ?a] [?f :follow/followee ?a] [?f :follow/state :accepted] " <>
          "[?f :follow/follower ?u] [?u :actor/local? true] [?o :object/received-at ?t] [(>= ?t #{cutoff_followed})]"
    ]

    edns = for {_, where} <- rules, do: "[:find ?o :where #{where}]"

    rules
    |> Enum.zip(Client.query_many(Graph.client(), edns))
    |> Enum.reduce(%{}, fn {{reason, _}, answer}, acc ->
      {:ok, rows} = answer
      eids = Enum.map(rows, fn [e] -> e end)
      Map.update(acc, reason, eids, &(&1 ++ eids))
    end)
    |> Map.new(fn {reason, eids} -> {reason, Enum.uniq(eids)} end)
  end

  # Everything that exists for the doomed objects, down the ownership chain
  # (object → poll → choice → vote). Bounded: the chain is four deep.
  defp children(doomed), do: children(doomed, [], 4)

  defp children([], acc, _), do: acc
  defp children(_, acc, 0), do: acc

  defp children(frontier, acc, depth) do
    pool = "[(ground [#{Enum.join(frontier, " ")}]) [?o ...]]"
    edns = for attr <- @dependents, do: "[:find ?d :where #{pool} [?d :#{attr} ?o]]"

    found =
      Client.query_many(Graph.client(), edns)
      |> Enum.flat_map(fn {:ok, rows} -> Enum.map(rows, &hd/1) end)
      |> Enum.uniq()
      |> Kernel.--(acc)

    children(found, acc ++ found, depth - 1)
  end
end
