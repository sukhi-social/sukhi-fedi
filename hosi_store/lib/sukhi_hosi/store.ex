# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Store do
  @moduledoc """
  The one connection to hosigraph, and what the domain says about its attributes.

  There is no table here. An attribute belongs to what it says (`object/published`, `follow/state`),
  and a thing that is many (likes, tags) is a many-valued attribute, not a join table.

  hosigraph has no tuple and no fulltext attribute, so where sukhi's graph store has a tuple
  identity (`follow/pair`) the domain keeps a string key of its own.
  """

  @schema %{
    "actor/id": %{type: :string, unique: :identity},
    "actor/username": %{type: :string},
    "actor/host": %{type: :string},
    "actor/local?": %{type: :boolean},
    "actor/pinned": %{type: :ref, card: :many},
    "object/id": %{type: :string, unique: :identity},
    "object/attributed-to": %{type: :ref},
    "object/published": %{type: :long},
    "object/local?": %{type: :boolean},
    "object/visibility": %{type: :keyword},
    "object/in-reply-to": %{type: :ref},
    "object/root": %{type: :ref},
    "object/content-html": %{type: :string},
    "object/tags": %{type: :string, card: :many},
    "object/liked-by": %{type: :ref, card: :many},
    "object/mentions": %{type: :ref, card: :many},
    "activity/id": %{type: :string, unique: :identity},
    "activity/type": %{type: :keyword},
    "activity/actor": %{type: :ref},
    "activity/object": %{type: :ref},
    "activity/published": %{type: :long},
    # `(key, order)` pairs that `Hosi.highest_in` walks: the newest posts of some authors, the newest
    # boosts of some people. The store keeps them up to date; they are never written, and not retracted.
    "object/by+at": %{tuple: [:"object/attributed-to", :"object/published"]},
    "activity/by+at": %{tuple: [:"activity/actor", :"activity/published"]},
    "follow/follower": %{type: :ref},
    "follow/followee": %{type: :ref},
    "follow/state": %{type: :keyword},
    "follow/pair": %{type: :string, unique: :identity},
    "follow/at": %{type: :long},
    "notification/key": %{type: :string, unique: :identity},
    "notification/recipient": %{type: :ref},
    "notification/from": %{type: :ref},
    "notification/type": %{type: :keyword},
    "notification/note": %{type: :ref},
    "notification/at": %{type: :long},
    "outbox/kind": %{type: :string},
    "outbox/object": %{type: :ref},
    "outbox/actor": %{type: :ref},
    "outbox/ap-id": %{type: :string},
    "relay/name": %{type: :string, unique: :identity},
    "relay/cursor": %{type: :long}
  }

  def schema, do: @schema

  @doc """
  Open (or create) the database in `dir`. The khana is `dtlv: path` (one process per call), or
  `jvm: {java, jar}` (one JVM that stays; it is the one that can be read while it is written).
  """
  def start_link(opts) do
    # BEAM starts with SIGCHLD ignored, and then the khana's child process cannot be waited for.
    :os.set_signal(:sigchld, :default)

    Hosi.start_link(
      open: %{dir: Keyword.fetch!(opts, :dir), schema: @schema, config: %{khana: khana(opts)}}
    )
  end

  defp khana(opts) do
    case Keyword.get(opts, :jvm) do
      {java, jar} -> [:jvm, java, jar]
      nil -> [:dtlv, Keyword.fetch!(opts, :dtlv)]
    end
  end

  @doc """
  Rows of a Datalog query, each row a list. `inputs` are `[:scalar, v]`, `[:coll, vs]`, `[:rel, rows]`,
  in the order of the query's `:in` (after `$`).
  """
  def rows(db, query, inputs \\ []) do
    {:ok, [rows]} = Hosi.query_many(db, [%{q: query, inputs: inputs}])
    rows
  end

  @doc "The one entity with this identity value, or nil."
  def lookup(db, attr, value) do
    case rows(db, "[:find ?e :in $ ?v :where [?e :#{attr} ?v]]", [[:scalar, value]]) do
      [[id]] -> id
      [] -> nil
    end
  end

  @doc "What these entities say now: a map of attribute to its values, per id, in order."
  def entities(_db, []), do: []

  def entities(db, ids) do
    {:ok, es} = Hosi.get_entities(db, ids)
    es
  end

  @doc "Ops that take every value of `id` away (the facts stay in the history; `erase` is another thing)."
  def retract_ops(db, id), do: retract_ops_many(db, [id])

  @doc "`retract_ops/2` for each of `ids`, with one read for all of them."
  def retract_ops_many(db, ids) do
    ids = Enum.uniq(ids)

    for {id, e} <- Enum.zip(ids, entities(db, ids)), {attr, values} <- e, not derived?(attr), v <- values do
      [:delete, id, attr, wrap(attr, v)]
    end
  end

  # a tuple attribute is made by the store from its parts: reading it shows it, writing it is refused
  defp derived?(attr), do: Map.has_key?(@schema[attr] || %{}, :tuple)

  @doc "A value as an op wants it: a reference is `[:ref id]`."
  def wrap(attr, v), do: if(@schema[attr][:type] == :ref, do: [:ref, v], else: v)

  def now_us, do: System.os_time(:microsecond)

  # A hosigraph id is `(ms since 2026-01-01) << 21 | seq`: the time it was written is in it, so a
  # time bound can be asked for as an id bound.
  @epoch_ms 1_767_225_600_000
  def id_at_ms(ms), do: max(ms - @epoch_ms, 0) |> Bitwise.bsl(21)
  def ms_of_id(id), do: Bitwise.bsr(id, 21) + @epoch_ms
end
