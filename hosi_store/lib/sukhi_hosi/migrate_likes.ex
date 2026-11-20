# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.MigrateLikes do
  @moduledoc """
  Moving likes from PostgreSQL to hosigraph, by hand: `copy/3`, then `verify/3`, then (outside this
  module) the switch of `like:` in the config. It is run by a person, once, with the writes of likes
  stopped; it can be run again.

  The old side is either sukhi's own tables (`domain:` given: its `reactions` with the favourite emoji,
  joined to `notes` and `accounts`; our people's IRIs are built from the domain, a remote one is its
  `actor_uri`, as in `ImportPg`) or a table of `(id, note_iri, actor_iri)` (`table:`, default
  `old_likes`). A like is carried by the IRIs of the post
  and of the person, since those are the identities hosigraph knows them by; so the posts and the
  people have to be in hosigraph before their likes. A like whose post or person is not there is
  not written and not forgotten: it is in `missing` of the report, for the person to look at.

  What is copied is history. Nothing is told to the relay and no one is notified: those happened
  when the like was made, and `Notes.like` is the one that does them for a like made now.

  Running it again is safe: a like that is already there is counted as `already` and left alone,
  so a copy that stopped half way is finished by running it once more.
  """

  alias SukhiHosi.{Actors, Notes, Store}

  @batch 500
  @favourite "⭐"

  @doc """
  Copy every like of `table` (default `old_likes`), or of sukhi's `reactions` when `domain:` is given, into `db`, in batches of `batch:` (default #{@batch}).
  Returns `%{copied: n, already: n, missing: [{note_iri, actor_iri}]}`.
  """
  def copy(db, pg, opts \\ []) do
    src = source!(opts)
    batch = Keyword.get(opts, :batch, @batch)
    loop(db, pg, src, batch, 0, %{copied: 0, already: 0, missing: []})
  end

  defp loop(db, pg, src, batch, after_id, report) do
    case page(pg, src, after_id, batch) do
      [] ->
        %{report | missing: Enum.reverse(report.missing)}

      rows ->
        pairs = for [_, note_iri, actor_iri] <- rows, do: {note_iri, actor_iri}
        %{copied: c, already: a, missing: m} = write_batch(db, pairs)

        report = %{
          copied: report.copied + c,
          already: report.already + a,
          missing: Enum.reverse(m, report.missing)
        }

        [last_id, _, _] = List.last(rows)
        loop(db, pg, src, batch, last_id, report)
    end
  end

  # No guard on the write: making a like that is already there changes nothing but adds one more
  # event to the log, so a like made by someone between our look and our write is harmless.
  defp write_batch(db, pairs) do
    {found, missing} = pairs |> Enum.uniq() |> resolve(db)
    present = liked_by(db, found)
    {have, todo} = Enum.split_with(found, fn {_, n, a} -> MapSet.member?(present, {n, a}) end)

    if todo != [] do
      {:ok, _} = Hosi.write(db, for({_, n, a} <- todo, do: [:create, n, :"object/liked-by", [:ref, a]]))
    end

    %{copied: length(todo), already: length(have), missing: missing}
  end

  # {[{pair, note_id, actor_id}], [pair]}: the ones hosigraph knows both ends of, and the ones it does not
  defp resolve(pairs, db) do
    {found, missing} =
      pairs
      |> Enum.map(fn {n, a} = pair -> {pair, find(&Notes.find/2, db, n), find(&Actors.find/2, db, a)} end)
      |> Enum.split_with(fn {_, n, a} -> n && a end)

    {found, Enum.map(missing, fn {pair, _, _} -> pair end)}
  end

  # the {note, actor} pairs hosigraph already has, among the notes of `found`
  defp liked_by(db, found) do
    ids = found |> Enum.map(fn {_, n, _} -> n end) |> Enum.uniq()

    ids
    |> Enum.zip(Store.entities(db, ids))
    |> Enum.flat_map(fn {n, e} -> for a <- Map.get(e, :"object/liked-by", []), do: {n, a} end)
    |> MapSet.new()
  end

  @doc """
  Look at both sides, for a person to read before the switch. `source` is how many different likes the
  old table has; `found` how many of them hosigraph has; `absent` the ones it does not (with the reason:
  `:no_note`, `:no_actor`, or `:not_copied`); `extra` how many likes hosigraph has that the table does not
  (before the switch there should be none; after it, the new ones).
  """
  def verify(db, pg, opts \\ []) do
    src = source!(opts)
    %{rows: rows} = Postgrex.query!(pg, "SELECT DISTINCT note_iri, actor_iri FROM (#{src.like}) l", src.args)
    pairs = for [n, a] <- rows, do: {n, a}

    seen =
      for {n_iri, a_iri} = pair <- pairs do
        note = find(&Notes.find/2, db, n_iri)
        actor = find(&Actors.find/2, db, a_iri)

        why =
          cond do
            is_nil(note) -> :no_note
            is_nil(actor) -> :no_actor
            liked?(db, note, actor) -> :found
            true -> :not_copied
          end

        {pair, why}
      end

    found = Enum.count(seen, fn {_, why} -> why == :found end)
    all = db |> Store.rows("[:find ?n ?a :where [?n :object/liked-by ?a]]") |> length()

    %{
      source: length(pairs),
      found: found,
      absent: for({pair, why} <- seen, why != :found, do: {pair, why}),
      extra: all - found
    }
  end

  # a person with no IRI (a remote row that has no `actor_uri`) is one hosigraph cannot know
  defp find(_fun, _db, nil), do: nil
  defp find(fun, db, iri), do: fun.(db, iri)

  defp liked?(db, note, actor) do
    [e] = Store.entities(db, [note])
    actor in Map.get(e, :"object/liked-by", [])
  end

  # `$1 $2` of the query are the cursor and the batch; what the source needs besides is `args`, after them.
  defp page(pg, src, after_id, batch) do
    %{rows: rows} =
      Postgrex.query!(
        pg,
        "SELECT id, note_iri, actor_iri FROM (#{src.like}) l WHERE id > $#{length(src.args) + 1} ORDER BY id LIMIT $#{length(src.args) + 2}",
        src.args ++ [after_id, batch]
      )

    rows
  end

  # `like` is a query that gives `(id, note_iri, actor_iri)`; `args` are the values its `$n` take
  defp source!(opts) do
    case Keyword.fetch(opts, :domain) do
      {:ok, domain} when is_binary(domain) ->
        # a favourite is the reaction carrying the favourite emoji (`Notes.Interactions.favourite_emoji/0`)
        %{
          like: """
          SELECT r.id AS id, n.ap_id AS note_iri,
                 CASE WHEN a.domain IS NULL THEN 'https://' || $1::text || '/users/' || a.username ELSE a.actor_uri END AS actor_iri
          FROM reactions r JOIN notes n ON n.id = r.note_id JOIN accounts a ON a.id = r.account_id
          WHERE r.emoji = $2::text AND n.ap_id IS NOT NULL
          """,
          args: [domain, @favourite]
        }

      :error ->
        table = Keyword.get(opts, :table, "old_likes")
        if table =~ ~r/\A[a-z_][a-z0-9_]*\z/, do: table, else: raise(ArgumentError, "table name: #{inspect(table)}")
        %{like: "SELECT id, note_iri, actor_iri FROM #{table}", args: []}
    end
  end
end
