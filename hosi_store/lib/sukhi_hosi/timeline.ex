# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Timeline do
  @moduledoc """
  Reading. Each timeline is one query that picks its page, newest first; the visibility is part
  of the query, not a filter after it. A page is asked for by an id (`before:`): a hosigraph id
  grows with the order things were written, so it does the work sukhi's `sid` does.

  Home is put together at read time (as in `Graph.Read.home`): the posts of the people you follow
  and your own, and what they boosted, merged by when each appeared; a post seen twice is one row
  with `via` naming the boosters. Its cursor is a time (`at`), because a boost has no id of a
  post's kind.
  """

  alias SukhiHosi.{Actors, Follows, Store}

  @max_id 9_223_372_036_854_775_807

  def public(db, opts \\ []) do
    clauses = if opts[:local], do: ["[?o :object/local? true]"], else: []
    page(db, [:public], clauses, {"", []}, opts)
  end

  @doc """
  One person's posts, newest first by when they were posted (`object/by+at`, walked by `highest_in`:
  about one seek, not a window that widens). `before:` is a post id; the page starts after that post.
  """
  def author(db, actor, opts \\ []) do
    vis = Keyword.get(opts, :visibilities, [:public, :unlisted])
    limit = Keyword.get(opts, :limit, 20)
    place = if before = opts[:before], do: place_of(db, before), else: nil
    db |> newest_posts([actor], limit, place, &(&1 in vis)) |> then(&present(db, &1))
  end

  # The newest `limit` posts of `keys` that `keep?` takes (by the post's visibility). `highest_in`
  # takes no filter, so a page that is short after the filter asks for the next one (twice as big).
  defp newest_posts(db, keys, limit, place, keep?, n \\ nil, acc \\ []) do
    n = n || limit
    opts = if place, do: [after: place], else: []
    {:ok, page} = Hosi.highest_in(db, :"object/by+at", keys, n, opts)
    es = Store.entities(db, Enum.map(page, & &1.id))
    kept = for {p, e} <- Enum.zip(page, es), keep?.(e |> Map.get(:"object/visibility", []) |> List.first()), do: p.id
    acc = acc ++ kept

    cond do
      length(acc) >= limit -> Enum.take(acc, limit)
      length(page) < n -> acc
      true -> newest_posts(db, keys, limit, %{val: List.last(page).val, id: List.last(page).id}, keep?, n * 2, acc)
    end
  end

  # where a post stands in the order of `object/by+at`: its time and its id
  defp place_of(db, id) do
    case Store.entities(db, [id]) do
      [%{"object/published": [at | _]}] -> %{val: at, id: id}
      _ -> %{val: Store.ms_of_id(id) * 1000, id: id}
    end
  end

  def tagged(db, tag, opts \\ []) do
    page(db, [:public], ["[?o :object/tags ?x]"], {"?x", [[:scalar, String.downcase(tag)]]}, opts)
  end

  @doc "Everything in the thread that `object` is in, oldest first."
  def thread(db, object, opts \\ []) do
    [e] = Store.entities(db, [object])
    root = e |> Map.fetch!(:"object/root") |> hd()
    vis = Keyword.get(opts, :visibilities, [:public, :unlisted])

    page(db, vis, ["[?o :object/root ?x]"], {"?x", [[:scalar, root]]}, Keyword.put(opts, :order, :asc))
  end

  @doc "Posts whose text contains `text` (lower-cased). A scan: hosigraph has no fulltext attribute yet."
  def search(db, text, opts \\ []) do
    page(
      db,
      Keyword.get(opts, :visibilities, [:public]),
      ["[?o :object/content-html ?h]", "[(clojure.string/lower-case ?h) ?l]", "[(clojure.string/includes? ?l ?x)]"],
      {"?x", [[:scalar, String.downcase(text)]]},
      opts
    )
  end

  def home(db, me, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    before = Keyword.get(opts, :before, Store.now_us() * 2)
    people = [me | Follows.followees(db, me)]

    merged =
      # one more than a page: what is later than the last one read is sure, and that is the page
      home_entries(db, people, limit, before, limit + 1)
      |> Enum.sort_by(&{&1.at, &1.id}, :desc)
      |> Enum.take(limit)

    rows = present(db, Enum.map(merged, & &1.id))

    Enum.zip_with(merged, rows, fn m, r ->
      Map.merge(r, %{at: m.at, via: Enum.map(m.via, &Actors.iri(db, &1))})
    end)
  end

  # What shows on home before `upper` (a time): the newest `n` posts of `people` and the newest `n`
  # boosts by them (two `highest_in`), folded into one row for each post. A post's time on the page is
  # its own, or its latest boost's: the later. What a source left out (it gave `n` and there are more)
  # is no later than that source's last one, so only what is later than that is sure; if that is fewer
  # than `limit`, ask again for twice as many.
  defp home_entries(db, people, limit, upper, n) do
    place = %{val: upper, id: 0}
    vis = [:public, :unlisted, :followers]
    {:ok, post_page} = Hosi.highest_in(db, :"object/by+at", people, n, after: place)
    {:ok, boost_page} = Hosi.highest_in(db, :"activity/by+at", people, n, after: place)

    posts = for {p, e} <- Enum.zip(post_page, Store.entities(db, Enum.map(post_page, & &1.id))), visible?(e, vis), do: p.id
    boosted = boosted_objects(db, boost_page, vis)

    candidates = Enum.uniq(posts ++ boosted)

    # When a post last appeared is its post time or its latest boost, wherever that boost is: a
    # post boosted after `upper` already showed on an earlier page and must not come again.
    all_boosts =
      if candidates == [],
        do: [],
        else:
          Store.rows(
            db,
            """
            [:find ?o ?bp ?a :in $ [?o ...] [?a ...]
             :where [?b :activity/type :Announce] [?b :activity/actor ?a] [?b :activity/object ?o]
                    [?b :activity/published ?bp]]
            """,
            [[:coll, candidates], [:coll, people]]
          )

    cand_entities = Enum.zip(candidates, Store.entities(db, candidates))
    own_time = Map.new(cand_entities, fn {o, e} -> {o, e |> Map.fetch!(:"object/published") |> hd()} end)

    # a post of someone we follow (or ours) appears at its own time, whichever page that falls on;
    # one that is only boosted does not
    shown_itself =
      for {o, e} <- cand_entities, hd(Map.fetch!(e, :"object/attributed-to")) in people, into: MapSet.new(), do: o
    by_object = Enum.group_by(all_boosts, &hd/1, fn [_, bp, a] -> {bp, a} end)

    entries =
      candidates
      |> Enum.map(fn o ->
        bs = Map.get(by_object, o, [])
        own = if MapSet.member?(shown_itself, o), do: [own_time[o]], else: []
        %{id: o, at: Enum.max(own ++ Enum.map(bs, &elem(&1, 0))), via: bs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}
      end)
      |> Enum.filter(&(&1.at < upper))

    cut = Enum.max(for(page <- [post_page, boost_page], length(page) == n, do: List.last(page).val), fn -> nil end)
    sure = if cut, do: Enum.filter(entries, &(&1.at > cut)), else: entries

    if length(sure) >= limit or cut == nil, do: sure, else: home_entries(db, people, limit, upper, n * 2)
  end

  defp visible?(e, vis), do: (e |> Map.get(:"object/visibility", []) |> List.first()) in vis

  # the posts that these boosts (the page of `highest_in`) are of, if visible and a boost
  defp boosted_objects(_db, [], _vis), do: []

  defp boosted_objects(db, page, vis) do
    acts = Store.entities(db, Enum.map(page, & &1.id))

    objects =
      for e <- acts, hd(Map.get(e, :"activity/type", [nil])) == :Announce, do: hd(Map.fetch!(e, :"activity/object"))

    objects = Enum.uniq(objects)
    for {o, e} <- Enum.zip(objects, Store.entities(db, objects)), visible?(e, vis), do: o
  end

  # ------------------------------------------------------------------ engine

  # A query's `:order-by` and `:limit` sort every match before they cut, so they do not make it
  # cheaper: narrow first. A page asks for the last few hours first and widens only if that was too
  # few (as `Graph.Read` does), and sorts and cuts here. (`author` and `home` do not need this: a
  # tuple of (who, when) is walked with `highest_in`.)
  defp page(db, vis, clauses, {decl, inputs}, opts) do
    limit = Keyword.get(opts, :limit, 20)
    asc? = opts[:order] == :asc

    query = fn lo, hi ->
      q = """
      [:find ?o :in $ [?v ...] ?lo ?hi #{decl}
       :where [?o :object/visibility ?v] [(> ?o ?lo)] [(< ?o ?hi)] #{Enum.join(clauses, " ")}]
      """

      db |> Store.rows(q, [[:coll, vis], [:scalar, lo], [:scalar, hi] | inputs]) |> List.flatten()
    end

    ids =
      if asc? do
        query.(Keyword.get(opts, :before, 0), @max_id) |> Enum.sort() |> Enum.take(limit)
      else
        hi = Keyword.get(opts, :before, @max_id)
        at_ms = if hi == @max_id, do: div(Store.now_us(), 1000), else: Store.ms_of_id(hi)

        windowed(at_ms, limit, 3_600_000, fn lower_ms -> query.(Store.id_at_ms(lower_ms), hi) end)
        |> Enum.sort(:desc)
        |> Enum.take(limit)
      end

    present(db, ids)
  end

  @windows_hours [6, 24, 96, 384, 1536, nil]

  # Ask for the last 6 hours before `upper` (in the unit `hour` of the bound), then 24, ... then
  # everything; stop when there are `limit` rows. `fun` gets the lower bound (0 for "everything").
  defp windowed(upper, limit, hour, fun) do
    Enum.reduce_while(@windows_hours, [], fn h, _ ->
      rows = fun.(if h, do: max(upper - h * hour, 0), else: 0)
      if length(rows) >= limit or h == nil, do: {:halt, rows}, else: {:cont, rows}
    end)
  end

  defp present(_db, []), do: []

  defp present(db, ids) do
    es = Store.entities(db, ids)
    authors = es |> Enum.map(&(&1 |> Map.fetch!(:"object/attributed-to") |> hd())) |> Enum.uniq()
    iris = authors |> then(&Store.entities(db, &1)) |> Enum.map(&(&1 |> Map.fetch!(:"actor/id") |> hd()))
    by_author = Map.new(Enum.zip(authors, iris))

    for {id, e} <- Enum.zip(ids, es) do
      first = fn k -> e |> Map.get(k, []) |> List.first() end

      %{
        id: id,
        iri: first.(:"object/id"),
        author: Map.fetch!(by_author, first.(:"object/attributed-to")),
        html: first.(:"object/content-html"),
        published: first.(:"object/published"),
        visibility: first.(:"object/visibility"),
        via: []
      }
    end
  end
end
