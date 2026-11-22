# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Notifications do
  @moduledoc """
  What a person is told. Today a notification is an entity in the same database, found by
  `notification/recipient`; the whole interface is `list`, `dismiss`, `clear` and the ops that
  make one. Nothing outside this module knows where they live, so that they can move to a small
  khana of the person's own (a window onto the same log) without anyone else changing.

  A notification is written in the same write as what causes it (a like, a follow), so there is never a like without
  its notification (sukhi writes it after the commit, apart). Taking the cause away takes the
  notification away (Mastodon does the same for an unfavourite). Its `key` is an identity, so one
  cause can tell once.

  Read ＞ write ＞ erase holds: they are read every time the list is opened, written once per
  cause, and erased by a person's own hand or with the account.
  """

  alias SukhiHosi.Store

  def key(type, note, from), do: "#{type}:#{note}:#{from}"

  @doc """
  The ops that tell the author of `note` that `from` did `type` to it (tmp number `n`). None when
  `from` is the author, or the author is not an account here (a remote author is not told by us).
  """
  def ops(db, n, type, note, from) do
    [obj] = Store.entities(db, [note])
    author = obj |> Map.fetch!(:"object/attributed-to") |> hd()
    [a] = Store.entities(db, [author])

    if author == from or not (a |> Map.get(:"actor/local?", [false]) |> hd()) do
      []
    else
      [
        [:create, [:tmp, n], :"notification/key", key(type, note, from)],
        [:create, [:tmp, n], :"notification/recipient", [:ref, author]],
        [:create, [:tmp, n], :"notification/from", [:ref, from]],
        [:create, [:tmp, n], :"notification/type", type],
        [:create, [:tmp, n], :"notification/note", [:ref, note]],
        [:create, [:tmp, n], :"notification/at", Store.now_us()]
      ]
    end
  end

  @doc """
  The ops that tell each of `mentioned` that the post `note` (a ref: an id, or `[:tmp, n]`; `iri` is
  its identity, known before it is written) mentions them. `n` is the first tmp number; each
  recipient takes one. Not the author, not the ones who are not accounts here, each person once.
  """
  def mention_ops(db, n, note, iri, from, mentioned) do
    mentioned
    |> Enum.uniq()
    |> Enum.reject(&(&1 == from))
    |> Enum.filter(fn who ->
      [a] = Store.entities(db, [who])
      a |> Map.get(:"actor/local?", [false]) |> hd()
    end)
    |> Enum.with_index(n)
    |> Enum.flat_map(fn {who, i} ->
      [
        [:create, [:tmp, i], :"notification/key", "mention:#{iri}:#{who}"],
        [:create, [:tmp, i], :"notification/recipient", [:ref, who]],
        [:create, [:tmp, i], :"notification/from", [:ref, from]],
        [:create, [:tmp, i], :"notification/type", :mention],
        [:create, [:tmp, i], :"notification/note", [:ref, note]],
        [:create, [:tmp, i], :"notification/at", Store.now_us()]
      ]
    end)
  end

  @doc """
  The ops that tell `to` that `from` followed them (`:follow`) or asked to (`:follow_request`).
  There is no note; the key is made of `to` where a note would be, so that one person following two
  people tells each of them (and `undo_ops` is given `to` in the note's place). None when `to` is `from`, or is not an account here.
  """
  def follow_ops(db, n, type, from, to) when type in [:follow, :follow_request] do
    [t] = Store.entities(db, [to])

    if to == from or not (t |> Map.get(:"actor/local?", [false]) |> hd()) do
      []
    else
      [
        [:create, [:tmp, n], :"notification/key", key(type, to, from)],
        [:create, [:tmp, n], :"notification/recipient", [:ref, to]],
        [:create, [:tmp, n], :"notification/from", [:ref, from]],
        [:create, [:tmp, n], :"notification/type", type],
        [:create, [:tmp, n], :"notification/at", Store.now_us()]
      ]
    end
  end

  @doc "Ops that take the notification of this cause away (none if there is none)."
  def undo_ops(db, type, note, from) do
    case Store.lookup(db, :"notification/key", key(type, note, from)) do
      nil -> []
      id -> Store.retract_ops(db, id)
    end
  end

  @doc "`recipient`'s notifications, newest first. `:before` (an id) and `:limit` (20) page it."
  def list(db, recipient, opts \\ []) do
    before = Keyword.get(opts, :before)
    limit = Keyword.get(opts, :limit, 20)

    ids =
      db
      |> Store.rows("[:find ?n :in $ ?r :where [?n :notification/recipient ?r]]", [[:scalar, recipient]])
      |> List.flatten()
      |> Enum.filter(&(before == nil or &1 < before))
      |> Enum.sort(:desc)
      |> Enum.take(limit)

    for {id, e} <- Enum.zip(ids, Store.entities(db, ids)) do
      first = fn k -> e |> Map.get(k, []) |> List.first() end
      %{id: id, type: first.(:"notification/type"), from: first.(:"notification/from"), note: first.(:"notification/note"), at: first.(:"notification/at")}
    end
  end

  @doc "How many of `recipient`'s are newer than `after_id` (what a read marker leaves unread)."
  def count_after(db, recipient, after_id) do
    db
    |> Store.rows(
      "[:find ?n :in $ ?r ?after :where [?n :notification/recipient ?r] [(> ?n ?after)]]",
      [[:scalar, recipient], [:scalar, after_id]]
    )
    |> length()
  end

  @doc "Take one away, if it is `recipient`'s. `:ok` or `:not_found`."
  def dismiss(db, recipient, id) do
    case Store.entities(db, [id]) do
      [%{"notification/recipient": [^recipient]}] ->
        {:ok, _} = Hosi.write(db, Store.retract_ops(db, id))
        :ok

      _ ->
        :not_found
    end
  end

  @doc "Take all of `recipient`'s away, in one write."
  def clear(db, recipient) do
    ids =
      db
      |> Store.rows("[:find ?n :in $ ?r :where [?n :notification/recipient ?r]]", [[:scalar, recipient]])
      |> List.flatten()

    if ids != [], do: {:ok, _} = Hosi.write(db, Store.retract_ops_many(db, ids))
    length(ids)
  end
end
