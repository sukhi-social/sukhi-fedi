# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.ImportPg do
  @moduledoc """
  Copying the people and the posts of sukhi's PostgreSQL (`accounts`, `notes`) into hosigraph, by
  hand, before the first operation (likes: `MigrateLikes`) is switched over. It is run by a person,
  with the writes of what it copies stopped; it can be run again.

  Order: `actors/3`, then `notes/3` (a post needs its author), then `verify/3`.

  What is carried:
    * a person: `actor/id` (the IRI: ours is `https://<domain>/users/<username>`, a remote one is
      its `actor_uri`), `actor/username`, `actor/host`, `actor/local?`
    * a post: `object/id` (`ap_id`), its author, `published` (microseconds), `local?`, `visibility`,
      the HTML to show (`content_html`, else `content`: `Note.html/1`'s rule), and, for a reply,
      `in-reply-to` and `root` (a post with no parent is the root of its own thread)

  What is not (yet): tags, mentions, media, polls, content warnings, boosts, follows, pins, and
  any notification. Those are separate steps; a post copied here has none of them.

  What is copied is history: nothing is told to the relay and no one is notified.

  A post is written after the post it answers (by depth in the thread, then by id), so `root` can be
  read from the parent. A thread whose parent is not in `notes` starts there: the parent is not
  known to us, and `in-reply-to` is left off (the same as for a remote reply whose parent never
  arrived). A cycle (it should not exist) is cut where it closes.

  The index of the posts (id, IRI, parent IRI) is held in memory for the run: a few hundred bytes a
  post, which is fine for the sizes sukhi is meant for and not for millions of posts.

  Running it again is safe: what is already there (by IRI) is counted as `already` and left alone.
  """

  alias SukhiHosi.Copy

  @batch 200

  @doc """
  Copy the accounts. `domain:` (required) is this server's, for the IRIs of its own people.
  Returns `%{copied: n, already: n, skipped: [{account_id, reason}]}`.
  """
  def actors(db, pg, opts) do
    domain = Keyword.fetch!(opts, :domain)
    batch = Keyword.get(opts, :batch, @batch)
    actors_loop(db, pg, domain, batch, 0, %{copied: 0, already: 0, skipped: []})
  end

  defp actors_loop(db, pg, domain, batch, after_id, report) do
    %{rows: rows} =
      Postgrex.query!(pg, "SELECT id, username, domain, actor_uri FROM accounts WHERE id > $1 ORDER BY id LIMIT $2", [after_id, batch])

    if rows == [] do
      report
    else
      r = Copy.actors(db, for([id, u, d, uri] <- rows, do: %{id: id, username: u, domain: d, actor_uri: uri}), domain)

      report = %{
        copied: report.copied + r.copied,
        already: report.already + r.already,
        skipped: report.skipped ++ r.skipped
      }

      [last | _] = List.last(rows)
      actors_loop(db, pg, domain, batch, last, report)
    end
  end

  @doc """
  Copy the posts (the people first: `actors/3`). `domain:` as above. A post whose author is not in
  hosigraph (or has no `ap_id`) is not written and not forgotten: it is in `missing`.
  Returns `%{copied: n, already: n, missing: [{note_id, reason}]}`.
  """
  def notes(db, pg, opts) do
    domain = Keyword.fetch!(opts, :domain)
    batch = Keyword.get(opts, :batch, @batch)
    people = people(pg, domain)

    {order, no_iri} = thread_order(pg)

    order
    |> Enum.chunk_by(fn {depth, _id} -> depth end)
    |> Enum.flat_map(fn same_depth -> Enum.chunk_every(same_depth, batch) end)
    |> Enum.reduce(%{copied: 0, already: 0, missing: Enum.map(no_iri, &{&1, :no_ap_id})}, fn chunk, report ->
      r = db |> Copy.notes(read_notes(pg, people, Enum.map(chunk, &elem(&1, 1))))
      %{copied: report.copied + r.copied, already: report.already + r.already, missing: report.missing ++ r.missing}
    end)
  end

  # account id => IRI, for every account that has one
  defp people(pg, domain) do
    %{rows: rows} = Postgrex.query!(pg, "SELECT id, username, domain, actor_uri FROM accounts", [])
    for [id, name, host, uri] <- rows, iri = Copy.iri_of(domain, name, host, uri), into: %{}, do: {id, iri}
  end

  # `{[{depth, id}], [id without ap_id]}`: the posts in the order they can be written, parents first
  defp thread_order(pg) do
    %{rows: rows} = Postgrex.query!(pg, "SELECT id, ap_id, in_reply_to_ap_id FROM notes ORDER BY id", [])
    {with_iri, no_iri} = Enum.split_with(rows, fn [_, ap_id, _] -> is_binary(ap_id) and ap_id != "" end)

    parent = for [_, ap_id, parent] <- with_iri, into: %{}, do: {ap_id, parent}
    known = MapSet.new(Map.keys(parent))
    depth = fn ap_id -> depth(ap_id, parent, known, MapSet.new(), 0) end

    order =
      for([id, ap_id, _] <- with_iri, do: {depth.(ap_id), id})
      |> Enum.sort()

    {order, for([id, _, _] <- no_iri, do: id)}
  end

  defp depth(ap_id, parent, known, seen, n) do
    p = Map.get(parent, ap_id)

    cond do
      p == nil or not MapSet.member?(known, p) -> n
      MapSet.member?(seen, p) -> n
      true -> depth(p, parent, known, MapSet.put(seen, ap_id), n + 1)
    end
  end

  defp read_notes(pg, people, ids) do
    %{rows: rows} =
      Postgrex.query!(
        pg,
        """
        SELECT id, account_id, ap_id, content, content_html, visibility, domain, created_at, in_reply_to_ap_id
        FROM notes WHERE id = ANY($1) ORDER BY id
        """,
        [ids]
      )

    for [id, account_id, ap_id, content, content_html, visibility, domain, created_at, parent_iri] <- rows do
      Copy.note(
        %{id: id, ap_id: ap_id, content: content, content_html: content_html, visibility: visibility, domain: domain, created_at: created_at, in_reply_to_ap_id: parent_iri},
        Map.get(people, account_id)
      )
    end
  end

  @doc """
  Look at both sides, for a person to read before the switch: `accounts` and `notes` are how many
  rows each table has (with an IRI), `actors` and `notes_found` how many of them hosigraph has, and
  `absent` the ones it does not, as `{:account | :note, id}`.
  """
  def verify(db, pg, opts) do
    domain = Keyword.fetch!(opts, :domain)
    people = people(pg, domain)
    %{rows: notes} = Postgrex.query!(pg, "SELECT id, ap_id FROM notes WHERE ap_id IS NOT NULL AND ap_id <> ''", [])

    have_actors = Copy.ids_of(db, :"actor/id", Map.values(people))
    have_notes = Copy.ids_of(db, :"object/id", Enum.map(notes, fn [_, iri] -> iri end))

    absent =
      for({id, iri} <- people, not Map.has_key?(have_actors, iri), do: {:account, id}) ++
        for [id, iri] <- notes, not Map.has_key?(have_notes, iri), do: {:note, id}

    %{
      accounts: map_size(people),
      notes: length(notes),
      actors: map_size(have_actors),
      notes_found: map_size(have_notes),
      absent: Enum.sort(absent)
    }
  end
end
