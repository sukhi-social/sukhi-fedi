# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Tail do
  @moduledoc """
  Keeping hosigraph beside sukhi's store: what is new there (a person, a post, a like) is written here,
  a little after. This is "both are written" without editing any path that writes to sukhi's
  store: each round reads what came after the last id this has seen (`SukhiHosi.Source`) and
  gives it to `Copy`. It follows the store and never changes what the store does, so a lost or
  repeated round does no damage.

  The cursors are in hosigraph (`relay/name` `tail:accounts`, `tail:notes`, `tail:likes` and `tail:sweep`), so they move with
  the data they describe. A cursor is moved only after what is before it is written, and writing
  is by IRI (what is there is left alone), so a round that stops half way is made good by the next.

  Three things keep a post from being passed by the cursor before it is written:

    * **Its author.** The people are copied first in each round. A post whose author is not in
      hosigraph still is asked of the source (`accounts_by_ids`) and copied, then the post is
      written; only an author the source does not have (a post left behind by a deleted person)
      is given up on, and named in `missing`.
    * **Its IRI.** A local post is inserted with no `ap_id` and stamped just after. A post with none
      stops the round there if it is younger than `grace:` seconds (default 60): the next round
      sees it stamped. An older one is given up on, named in `missing` as `:no_ap_id`.
    * **A reply before its parent.** A reply is written after the post it answers when both are in
      the round. If the parent comes in a later round, the reply stays the head of its own thread
      (the same as a remote reply whose parent never arrived); it is not rewritten.

  A like is followed after the posts, and waits for its post the same way: if the post of a like
  is not in hosigraph yet, the round stops at that like and the next one finds the post written
  (the post is the notes step's to write, so it is written once and in order). One whose post is
  still not there after `grace:` seconds, or is not in the source at all, is given up on and named
  in `likes_missing`. Only favourites are followed (`Copy.favourite/0`).

  A row that is deleted leaves nothing for a cursor on ids to see, so what left the store is found
  the other way: each round (`sweep: true`) looks at one window of the posts hosigraph has, newest
  first, and asks the source which of them it still has (`notes_by_ap_ids`) and who still likes
  them (`likes_of_notes`). A post it does not have is taken away (`Notes.forget_many_ops`: what
  `Notes.delete` writes, without the line for the relay, which was told when the delete was made);
  so is a like it does not have. The cursor `tail:sweep` is where the window ended; a window shorter
  than `batch` ends a pass, and the next starts from the newest. A source that cannot answer raises (see
  `SukhiHosi.Source`), and then nothing is taken away. What is taken away stays in the log
  (`Notes.delete` is a delete, not an erase).

  This takes the store to be the truth for what it follows. When a kind of write moves to hosigraph
  (a like made there, a post made there), what only hosigraph has would look gone: stop following
  that kind before it does.

  What is not followed at all: edits, follows, boosts, and every reaction but the favourite.
  Until hosigraph is read from, nothing reads what is stale.
  """

  alias SukhiHosi.{Copy, Notes, Store}

  @batch 200
  @grace_s 60

  @doc """
  One round. `source` is `{module, arg}` (`SukhiHosi.Source`); `domain:` (required) is this server's.
  `sweep: false` leaves out the last step, the sweep (above). Returns `%{actors: n, notes: n, likes: n,
  missing: [{note_id, reason}], likes_missing: [{like_id, reason}], skipped: [{account_id, reason}],
  gone: n, unliked: n}` (the numbers are how many were written this round).
  """
  def sync(db, source, opts) do
    domain = Keyword.fetch!(opts, :domain)
    batch = Keyword.get(opts, :batch, @batch)
    grace = Keyword.get(opts, :grace, @grace_s)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    people = people(db, source, domain, batch, %{actors: 0, skipped: []})
    notes = notes(db, source, domain, batch, grace, now, %{notes: 0, missing: []})
    likes = likes(db, source, domain, batch, grace, now, %{likes: 0, missing: []})
    swept = if Keyword.get(opts, :sweep, true), do: sweep(db, source, domain, batch), else: %{gone: 0, unliked: 0}

    %{
      actors: people.actors,
      notes: notes.notes,
      likes: likes.likes,
      missing: notes.missing,
      likes_missing: likes.missing,
      skipped: people.skipped,
      gone: swept.gone,
      unliked: swept.unliked
    }
  end

  defp people(db, {mod, arg} = source, domain, batch, report) do
    {cursor, at} = cursor(db, "tail:accounts")

    case mod.accounts_after(arg, at, batch) do
      [] ->
        report

      rows ->
        r = Copy.actors(db, rows, domain)
        move(db, cursor, at, List.last(rows).id)
        people(db, source, domain, batch, %{actors: report.actors + r.copied, skipped: report.skipped ++ r.skipped})
    end
  end

  defp notes(db, {mod, arg} = source, domain, batch, grace, now, report) do
    {cursor, at} = cursor(db, "tail:notes")
    rows = mod.notes_after(arg, at, batch)
    {ready, held} = take_ready(rows, grace, now)

    {given_up, ready} = Enum.split_with(ready, &(not stamped?(&1)))
    missing = for r <- given_up, do: {r.id, :no_ap_id}

    cond do
      rows == [] ->
        report

      ready == [] and missing == [] ->
        # the first post of the round is one that is not stamped yet: wait for it
        report

      true ->
        iri = authors(db, source, domain, ready)
        r = Copy.notes(db, for(row <- ready, do: Copy.note(row, Map.get(iri, row.account_id))))

        # a post whose author the source does not have is given up on; the rest of the round is written
        last = (ready ++ given_up) |> Enum.map(& &1.id) |> Enum.max()
        move(db, cursor, at, last)

        report = %{notes: report.notes + r.copied, missing: report.missing ++ missing ++ r.missing}
        if held == [], do: notes(db, source, domain, batch, grace, now, report), else: report
    end
  end

  defp likes(db, {mod, arg} = source, domain, batch, grace, now, report) do
    {cursor, at} = cursor(db, "tail:likes")

    case mod.likes_after(arg, at, batch, Copy.favourite()) do
      [] ->
        report

      rows ->
        notes = arg |> mod.notes_by_ids(rows |> Enum.map(& &1.note_id) |> Enum.uniq()) |> Map.new(&{&1.id, &1})
        here = Copy.ids_of(db, :"object/id", for(n <- Map.values(notes), stamped?(n), do: n.ap_id))
        fates = Enum.map(rows, &{&1, fate(&1, notes, here, grace, now)})
        {passed, held} = Enum.split_while(fates, fn {_, fate} -> fate != :hold end)

        if passed == [] do
          # the first like of the round is one whose post is not here yet: wait for it
          report
        else
          {ready, given_up} = Enum.split_with(passed, fn {_, fate} -> fate == :ready end)
          ready = Enum.map(ready, &elem(&1, 0))
          iri = authors(db, source, domain, ready)

          {pairs, no_iri} =
            Enum.split_with(
              for(l <- ready, do: {l, {Map.fetch!(notes, l.note_id).ap_id, Map.get(iri, l.account_id)}}),
              fn {_, {_, actor}} -> actor != nil end
            )

          r = Copy.likes(db, Enum.map(pairs, &elem(&1, 1)))
          move(db, cursor, at, passed |> Enum.map(fn {l, _} -> l.id end) |> Enum.max())

          report = %{
            likes: report.likes + r.copied,
            missing: report.missing ++ for({l, {:give_up, why}} <- given_up, do: {l.id, why}) ++ for({l, _} <- no_iri, do: {l.id, :no_iri})
          }

          if held == [], do: likes(db, source, domain, batch, grace, now, report), else: report
        end
    end
  end

  # What to do with a like: write it (its post is in hosigraph), wait (its post is young and not
  # here yet), or give up (there will be no post to put it on).
  defp fate(like, notes, here, grace, now) do
    case Map.get(notes, like.note_id) do
      nil ->
        {:give_up, :no_note}

      note ->
        cond do
          stamped?(note) and Map.has_key?(here, note.ap_id) -> :ready
          DateTime.diff(now, note.created_at, :second) < grace -> :hold
          stamped?(note) -> {:give_up, :no_note}
          true -> {:give_up, :no_ap_id}
        end
    end
  end

  defp stamped?(row), do: is_binary(row.ap_id) and row.ap_id != ""

  # One window of the posts hosigraph has, newest first (`Hosi.highest` over `object/published`): a
  # post the store no longer has is taken away, and so is a like of a post it still has that the
  # store no longer has. The cursor (`tail:sweep`) is the last post of the window that stayed (0: the
  # newest). A window shorter than `batch` is the end of a pass: the cursor goes back to 0, so the
  # next round starts again from the newest.
  #
  # hosigraph is read before the store is. A like that is in hosigraph was in the store when it was
  # copied, so one the store does not have now was taken back; the other way round, a like made
  # between the two reads would look like one taken back.
  defp sweep(db, {mod, arg}, domain, batch) do
    {cursor, at} = cursor(db, "tail:sweep")
    {:ok, page} = Hosi.highest(db, :"object/published", batch, sweep_after(db, at))

    if page == [] do
      if at != 0, do: move(db, cursor, at, 0)
      %{gone: 0, unliked: 0}
    else
      ids = Enum.map(page, & &1.id)
      posts = for {id, %{"object/id": [iri | _], "object/attributed-to": [author | _]} = e} <- Enum.zip(ids, Store.entities(db, ids)), do: {id, iri, author, e}

      alive = arg |> mod.notes_by_ap_ids(for({_, iri, _, _} <- posts, do: iri)) |> Map.new(&{&1.ap_id, &1.id})
      {here, gone} = Enum.split_with(posts, fn {_, iri, _, _} -> Map.has_key?(alive, iri) end)

      forgotten = Notes.forget_many_ops(db, for({id, _, author, _} <- gone, do: {id, author}))
      unliked = untaken_likes(db, {mod, arg}, domain, here, alive)
      ops = forgotten ++ unliked
      if ops != [], do: {:ok, _} = Hosi.write(db, ops)

      next =
        case {length(page) < batch, List.last(here)} do
          {true, _} -> 0
          {false, {id, _, _, _}} -> id
          {false, nil} -> at
        end

      if next != at, do: move(db, cursor, at, next)

      %{gone: length(gone), unliked: length(unliked)}
    end
  end

  # `[after: place]` for the post the cursor is at; from the newest if it is 0 or that post is gone
  defp sweep_after(_db, 0), do: []

  defp sweep_after(db, id) do
    case Store.entities(db, [id]) do
      [%{"object/published": [at | _]}] -> [after: %{val: at, id: id}]
      _ -> []
    end
  end

  # the ops that take off the likes the store no longer has, for the posts of `here` (`{id, iri, author, entity}`)
  defp untaken_likes(_db, _source, _domain, [], _alive), do: []

  defp untaken_likes(db, {mod, arg}, domain, here, alive) do
    likes = mod.likes_of_notes(arg, for({_, iri, _, _} <- here, do: Map.fetch!(alive, iri)), Copy.favourite())
    accounts = mod.accounts_by_ids(arg, likes |> Enum.map(& &1.account_id) |> Enum.uniq())
    iri = for a <- accounts, i = Copy.iri_of(domain, a.username, a.domain, a.actor_uri), into: %{}, do: {a.id, i}
    people = Copy.ids_of(db, :"actor/id", Map.values(iri))

    # note id (the store's) => the people (hosigraph's) who still like it
    kept = Enum.group_by(likes, & &1.note_id, &Map.get(people, Map.get(iri, &1.account_id)))

    for {id, i, _, e} <- here,
        person <- Map.get(e, :"object/liked-by", []),
        person not in Map.get(kept, Map.fetch!(alive, i), []),
        do: [:delete, id, :"object/liked-by", [:ref, person]]
  end

  # the rows up to the first one that has no `ap_id` and is too young to give up on
  defp take_ready(rows, grace, now) do
    Enum.split_while(rows, fn r -> stamped?(r) or DateTime.diff(now, r.created_at, :second) >= grace end)
  end

  # account id => IRI, for the authors of `rows`; one that is not in hosigraph yet is copied from the source
  defp authors(db, {mod, arg}, domain, rows) do
    ids = rows |> Enum.map(& &1.account_id) |> Enum.uniq()
    accounts = mod.accounts_by_ids(arg, ids)
    Copy.actors(db, accounts, domain)
    for a <- accounts, iri = Copy.iri_of(domain, a.username, a.domain, a.actor_uri), into: %{}, do: {a.id, iri}
  end

  # `{entity, value}` of a cursor, made at 0 the first time
  defp cursor(db, name) do
    case Store.lookup(db, :"relay/name", name) do
      nil ->
        # the name is an identity, so two creators cannot both succeed: the loser looks again
        _ = Hosi.write(db, [[:create, [:tmp, 1], :"relay/name", name], [:create, [:tmp, 1], :"relay/cursor", 0]])
        cursor(db, name)

      c ->
        {:ok, [e]} = Hosi.get_entities(db, [c])
        {c, e |> Map.fetch!(:"relay/cursor") |> hd()}
    end
  end

  defp move(db, cursor, from, to) do
    case Hosi.write(db, [[:create, cursor, :"relay/cursor", to]], when: [[:holds, cursor, :"relay/cursor", from]]) do
      {:ok, _} -> :ok
      # another round moved it first: what it passed is written
      {:error, {:app, :conflict, _}} -> :ok
    end
  end
end
