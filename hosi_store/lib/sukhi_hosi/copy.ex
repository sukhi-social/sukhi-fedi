# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Copy do
  @moduledoc """
  Writing people and posts that sukhi already has into hosigraph: the one place that knows how.
  `ImportPg` (by hand, all of it) and `Tail` (the new ones, as they come) both call this, so a
  person or a post is made the same way whichever way it came.

  What is written is history: nothing is told to the relay and no one is notified. A person or a
  post is found by its IRI, so what is already there is counted as `already` and left alone.
  """

  alias SukhiHosi.{Notes, Store}

  @doc "The IRI of a person: ours (`domain` of the row is nil) is built from this server's domain, a remote one is its `actor_uri`. nil if there is none."
  def iri_of(domain, username, nil, _uri), do: "https://#{domain}/users/#{username}"
  def iri_of(_domain, _username, _host, uri) when is_binary(uri) and uri != "", do: uri
  def iri_of(_, _, _, _), do: nil

  @doc """
  Write people. Each is `%{id:, username:, domain:, actor_uri:}` (sukhi's `accounts` columns); `server:`
  is this server's domain. Returns `%{copied: n, already: n, skipped: [{id, :no_iri}]}`.
  """
  def actors(db, rows, server) do
    {known, skipped} =
      rows
      |> Enum.map(fn r -> {r, iri_of(server, r.username, r.domain, r.actor_uri)} end)
      |> Enum.split_with(fn {_, iri} -> iri != nil end)

    present = ids_of(db, :"actor/id", Enum.map(known, &elem(&1, 1)))
    {have, todo} = known |> Enum.uniq_by(&elem(&1, 1)) |> Enum.split_with(fn {_, iri} -> Map.has_key?(present, iri) end)

    if todo != [] do
      {:ok, _} = Hosi.write(db, todo |> Enum.with_index(1) |> Enum.flat_map(fn {{r, iri}, n} -> actor_ops(n, r, iri) end))
    end

    %{copied: length(todo), already: length(have), skipped: for({r, _} <- skipped, do: {r.id, :no_iri})}
  end

  defp actor_ops(n, %{domain: nil} = r, iri) do
    [
      [:create, [:tmp, n], :"actor/id", iri],
      [:create, [:tmp, n], :"actor/username", r.username],
      [:create, [:tmp, n], :"actor/local?", true]
    ]
  end

  defp actor_ops(n, r, iri) do
    [
      [:create, [:tmp, n], :"actor/id", iri],
      [:create, [:tmp, n], :"actor/username", r.username],
      [:create, [:tmp, n], :"actor/host", r.domain],
      [:create, [:tmp, n], :"actor/local?", false]
    ]
  end

  @doc """
  A row of sukhi's `notes` (`%{id:, account_id:, ap_id:, content:, content_html:, visibility:, domain:,
  created_at:, in_reply_to_ap_id:}`) as what `notes/2` takes. `author_iri` is the IRI of its author
  (nil when the author is not known).
  """
  def note(r, author_iri) do
    %{
      id: r.id,
      author_iri: author_iri,
      iri: r.ap_id,
      # what a reader is shown: the rendered form, else the text (`Note.html/1`)
      html: if(is_binary(r.content_html) and r.content_html != "", do: r.content_html, else: r.content || ""),
      visibility: visibility(r.visibility),
      local?: is_nil(r.domain),
      published: DateTime.to_unix(r.created_at, :microsecond),
      parent_iri: r.in_reply_to_ap_id
    }
  end

  @doc """
  Write posts (as `note/2` makes them), a post after the post it answers: the order inside the list
  is by depth, so a reply and its parent may come together. A reply whose parent is not in hosigraph
  nor in the list is the head of its own thread. A post whose author is not in hosigraph is not
  written and not forgotten: `{id, :no_author}` in `missing`.
  """
  def notes(db, notes) do
    inside = for n <- notes, into: %{}, do: {n.iri, n.parent_iri}

    notes
    |> Enum.sort_by(&{depth(&1.iri, inside, MapSet.new(), 0), &1.id})
    |> Enum.chunk_by(&depth(&1.iri, inside, MapSet.new(), 0))
    |> Enum.reduce(%{copied: 0, already: 0, missing: []}, fn chunk, acc ->
      r = write_notes(db, chunk)
      %{copied: acc.copied + r.copied, already: acc.already + r.already, missing: acc.missing ++ r.missing}
    end)
  end

  defp depth(iri, inside, seen, n) do
    p = Map.get(inside, iri)

    cond do
      p == nil or not Map.has_key?(inside, p) -> n
      MapSet.member?(seen, p) -> n
      true -> depth(p, inside, MapSet.put(seen, iri), n + 1)
    end
  end

  defp write_notes(db, notes) do
    present = ids_of(db, :"object/id", Enum.map(notes, & &1.iri))
    authors = ids_of(db, :"actor/id", for(n <- notes, n.author_iri, do: n.author_iri))
    parents = ids_of(db, :"object/id", for(n <- notes, n.parent_iri, do: n.parent_iri))

    {have, rest} = Enum.split_with(notes, &Map.has_key?(present, &1.iri))
    {todo, missing} = Enum.split_with(rest, &Map.has_key?(authors, &1.author_iri))

    if todo != [] do
      ops =
        todo
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {n, i} ->
          opts = [
            db: db,
            published: n.published,
            local?: n.local?,
            visibility: n.visibility,
            in_reply_to: Map.get(parents, n.parent_iri)
          ]

          Notes.object_ops(i, Map.fetch!(authors, n.author_iri), n.iri, n.html, opts)
        end)

      {:ok, _} = Hosi.write(db, ops)
    end

    %{copied: length(todo), already: length(have), missing: for(n <- missing, do: {n.id, :no_author})}
  end

  # sukhi says "public" | "unlisted" | "followers" | "private" | "direct"; anything else is the
  # narrowest, so a post is never shown to more people than it was written for
  def visibility("public"), do: :public
  def visibility("unlisted"), do: :unlisted
  def visibility(v) when v in ["followers", "private"], do: :followers
  def visibility(_), do: :direct

  @doc "`%{value => hosigraph id}` for the entities that have one of `values` as `attr` (an identity)."
  def ids_of(_db, _attr, []), do: %{}

  def ids_of(db, attr, values) do
    db
    |> Store.rows("[:find ?v ?e :in $ [?v ...] :where [?e :#{attr} ?v]]", [[:coll, Enum.uniq(values)]])
    |> Map.new(fn [v, e] -> {v, e} end)
  end
end
