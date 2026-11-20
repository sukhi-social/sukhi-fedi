# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Sweep do
  @moduledoc """
  Capacity cleanup of *remote* posts, as in `Graph.Sweep`. Never touched: remote actors, local
  posts, follows. A remote post is **kept** if any of these holds, each worked out from the
  graph on every run (a stored flag has to be taken off again, and forgetting leaves something
  that can never be swept):

    * `:local_thread` — a local post is in its thread
    * `:young_thread` — some post of its thread is still inside the short TTL
    * `:local_touch`  — a local actor liked or boosted it, or it mentions one
    * `:followed`     — its author is followed by a local actor, and it is inside the long TTL

  Candidates are found by time; the rules run once per batch on them, one query each. What is
  left goes in one `erase` (the posts, and what hangs off them), then `clean` lets the bytes go.

  Options: `:now` (µs), `:ttl_followed_s` (90 days), `:ttl_other_s` (14 days), `:limit` (2000),
  `:dry_run`.
  """

  alias SukhiHosi.Store

  @day 86_400

  # Things that exist *for* a post and point at it: when it goes, they go.
  @dependents [:"activity/object", :"outbox/object", :"notification/note"]
  # References that stay (the thing they point at may be gone; they say who or what, not whose).
  @edges [
    :"object/attributed-to",
    :"object/in-reply-to",
    :"object/root",
    :"object/liked-by",
    :"object/mentions",
    # a pin is only ever on one's own post, and a sweep takes only what came from elsewhere
    :"actor/pinned",
    :"activity/actor",
    :"follow/follower",
    :"follow/followee",
    :"outbox/actor",
    :"notification/recipient",
    :"notification/from"
  ]

  def dependents, do: @dependents
  def edges, do: @edges

  def run(db, opts \\ []) do
    now = Keyword.get(opts, :now) || Store.now_us()
    cut = now - Keyword.get(opts, :ttl_other_s, 14 * @day) * 1_000_000
    cut_followed = now - Keyword.get(opts, :ttl_followed_s, 90 * @day) * 1_000_000
    limit = Keyword.get(opts, :limit, 2000)

    candidates =
      db
      |> Store.rows(
        "[:find ?o ?r :in $ ?cut :where [?o :object/local? false] [?o :object/published ?p] [(< ?p ?cut)] [?o :object/root ?r]]",
        [[:scalar, cut]]
      )
      |> Enum.sort()
      |> Enum.take(limit)

    ids = Enum.map(candidates, &hd/1)
    roots = candidates |> Enum.map(&List.last/1) |> Enum.uniq()

    kept = %{
      local_thread: threads(db, roots, "[?x :object/local? true]", candidates, []),
      young_thread: threads(db, roots, "[?x :object/published ?p] [(>= ?p ?cut)]", candidates, [[:scalar, cut]], "?cut"),
      local_touch:
        MapSet.union(
          set(db, ids, "[?o :object/liked-by ?a] [?a :actor/local? true]"),
          set(db, ids, "[?b :activity/object ?o] [?b :activity/actor ?a] [?a :actor/local? true]")
        )
        |> MapSet.union(set(db, ids, "[?o :object/mentions ?a] [?a :actor/local? true]")),
      followed:
        set(
          db,
          ids,
          """
          [?o :object/attributed-to ?au] [?o :object/published ?p] [(>= ?p ?cutf)]
          [?f :follow/followee ?au] [?f :follow/state :accepted] [?f :follow/follower ?me] [?me :actor/local? true]
          """,
          "?cutf",
          [[:scalar, cut_followed]]
        )
    }

    keep = kept |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    sweep = Enum.reject(ids, &MapSet.member?(keep, &1))

    report = %{
      candidates: length(ids),
      kept: Map.new(kept, fn {reason, set} -> {reason, MapSet.size(set)} end),
      swept: length(sweep)
    }

    cond do
      Keyword.get(opts, :dry_run, false) or sweep == [] ->
        {:ok, report}

      true ->
        with {:ok, _} <- Hosi.erase(db, [[:ids, sweep], [:"owned-by", @dependents, sweep]]),
             {:ok, _} <- Hosi.clean(db) do
          {:ok, report}
        end
    end
  end

  # candidates whose thread root is in the set of roots that satisfy `clause`
  defp threads(db, roots, clause, candidates, extra, extra_decl \\ "") do
    hit =
      case roots do
        [] ->
          []

        _ ->
          db
          |> Store.rows(
            "[:find ?r :in $ [?r ...] #{extra_decl} :where [?x :object/root ?r] #{clause}]",
            [[:coll, roots] | extra]
          )
          |> List.flatten()
      end

    hit = MapSet.new(hit)
    for [o, r] <- candidates, MapSet.member?(hit, r), into: MapSet.new(), do: o
  end

  defp set(db, ids, clause, decl \\ "", extra \\ [])
  defp set(_db, [], _clause, _decl, _extra), do: MapSet.new()

  defp set(db, ids, clause, decl, extra) do
    db
    |> Store.rows("[:find ?o :in $ [?o ...] #{decl} :where #{clause}]", [[:coll, ids] | extra])
    |> List.flatten()
    |> MapSet.new()
  end
end
