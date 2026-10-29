# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Read do
  @moduledoc """
  Timelines and lookups over the graph. Each function is one query (or, for
  home, two issued together) and returns plain maps; pagination is by `sid`
  (Mastodon's `max_id`: `before:` is a sid, newest first), because a sid is
  time-ordered and stable.

  Visibility is part of the query, not a filter after it: a timeline asks
  for the visibilities it may show (`:visibilities`), and a Tombstone is
  never returned.

  Home is assembled **at read time** (decision in docs/DATALEVIN_SCHEMA.md):
  the posts of the accounts a local actor follows, plus what they boosted,
  merged by time; a post seen several times (posted, and boosted by two
  people) is one row with `via` listing the boosters. Nothing is stored per
  reader (`entry/*` stays unused).
  """

  alias SukhiFedi.{Graph, Snowflake}
  alias SukhiFedi.Datalevin.Edn

  @type row :: %{
          id: String.t(),
          sid: integer(),
          published: integer(),
          type: String.t(),
          author: String.t(),
          html: String.t(),
          summary: String.t(),
          sensitive?: boolean(),
          visibility: String.t(),
          language: String.t(),
          reply_to: String.t() | nil,
          via: [String.t()]
        }

  @listed [:public, :unlisted]
  @default_limit 20
  # How far back a timeline looks first, in hours; each pass widens it. The
  # last pass has no lower bound. See `windowed/2`.
  @windows_hours [6, 24, 96, 384, 1536, nil]

  # --------------------------------------------------------------- timelines

  @doc "The public timeline (`local: true` for this server's own posts only)."
  @spec public(keyword()) :: [row()]
  def public(opts \\ []) do
    local = if opts[:local], do: "[?o :object/local? true]", else: ""
    select(["[?o :object/visibility :public]", local], opts)
  end

  @doc "One author's posts, newest first. `:visibilities` defaults to what a stranger sees."
  @spec author(String.t(), keyword()) :: [row()]
  def author(actor_iri, opts \\ []) do
    select(
      ["[?a :actor/id #{lit(actor_iri)}]", "[?o :object/attributed-to ?a]", visibilities(opts)],
      opts
    )
  end

  @doc "Public posts with a hashtag (lower-cased, no `#`); `local: true` for this server's own."
  @spec tagged(String.t(), keyword()) :: [row()]
  def tagged(tag, opts \\ []) do
    local = if opts[:local], do: "[?o :object/local? true]", else: ""

    select(
      [
        "[?t :tagging/tag #{lit(tag)}]",
        "[?t :tagging/object ?o]",
        "[?o :object/visibility :public]",
        local
      ],
      opts
    )
  end

  @doc "Everything in a thread, oldest first."
  @spec thread(String.t(), keyword()) :: [row()]
  def thread(object_iri, opts \\ []) do
    root =
      case Graph.query!(
             "[:find ?r :where [?o :object/id #{lit(object_iri)}] [?o :object/root ?x] [?x :object/id ?r]]"
           ) do
        [[r]] -> r
        [] -> object_iri
      end

    select(
      ["[?r :object/id #{lit(root)}]", "[?o :object/root ?r]", visibilities(opts)],
      Keyword.put_new(opts, :order, :asc)
    )
  end

  @doc "Full-text search over `tokens` (the query is segmented by the caller: `Tokens.query_text/3`)."
  @spec search(String.t(), keyword()) :: [row()]
  def search(segmented, opts \\ []) do
    select(
      ["[(fulltext $ :object/tokens #{lit(segmented)}) [[?o]]]", visibilities(opts)],
      opts
    )
  end

  @doc """
  A local actor's home: followees' posts and boosts, folded. Own posts
  included. Returns `limit` rows, newest first by when each *appeared*
  (a post's time, or its latest boost's), each carrying a `cursor`: pass the
  last row's as `before:` for the next page. (A boost has no sid of its own,
  so home pages by this time-ordered cursor, not by `sid`.)
  """
  @spec home(String.t(), keyword()) :: [row()]
  def home(actor_iri, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    me = "[?me :actor/id #{lit(actor_iri)}]"
    followee = "[?f :follow/follower ?me] [?f :follow/state :accepted] [?f :follow/followee ?a]"

    vis = visibilities(Keyword.put(opts, :visibilities, [:public, :unlisted, :followers]))
    upper_us = if b = opts[:before], do: Snowflake.to_unix_ms(b) * 1000
    opts = Keyword.delete(opts, :before)

    windowed(upper_us, limit, fn lower_us ->
      home_rows(me, followee, vis, lower_us, upper_us, opts)
    end)
    |> Enum.take(limit)
  end

  defp home_rows(me, followee, vis, lower_us, upper_us, opts) do
    objects = fn tail ->
      [sid_range(lower_us, upper_us) | tail]
    end

    own = select_once(objects.([me, "[?o :object/attributed-to ?me]", vis]), opts)
    followed = select_once(objects.([me, followee, "[?o :object/attributed-to ?a]", vis]), opts)
    boosts = boosts(me, followee, time_range("?bp", lower_us, upper_us), opts)

    (own ++ followed ++ boosts)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_, [first | _] = rows} ->
      at = rows |> Enum.map(&Map.get(&1, :at, &1.published)) |> Enum.max()

      %{first | via: rows |> Enum.flat_map(& &1.via) |> Enum.uniq()}
      |> Map.merge(%{at: at, cursor: cursor(at, first.sid)})
    end)
    |> Enum.sort_by(&{&1.at, &1.sid}, :desc)
  end

  # A Snowflake of the appearance time; the low bits come from the post's sid so two rows in one millisecond differ.
  defp cursor(at_us, sid), do: Snowflake.encode(div(at_us, 1000), Bitwise.band(sid, 0xFFFF))

  @doc "A local actor's notifications, newest first."
  @spec notifications(String.t(), keyword()) :: [map()]
  def notifications(actor_iri, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    before = if b = opts[:before], do: "[(< ?sid #{b})]", else: ""

    Graph.query!("""
    [:find ?sid ?type ?at ?from ?aid ?oid
     :where [?u :actor/id #{lit(actor_iri)}] [?n :notification/recipient ?u]
            [?n :notification/sid ?sid] [?n :notification/type ?type] [?n :notification/at ?at]
            [?n :notification/from ?f] [?f :actor/id ?from]
            [?n :notification/source ?s]
            [(get-else $ ?s :activity/id "") ?aid] [(get-else $ ?s :object/id "") ?oid]
            #{before}
     :order-by [?sid :desc] :limit #{limit}]
    """)
    |> Enum.map(fn [sid, type, at, from, aid, oid] ->
      %{
        sid: sid,
        type: String.trim_leading(to_string(type), ":"),
        at: at,
        from: from,
        source: aid <> oid
      }
    end)
  end

  # ------------------------------------------------------------------ engine

  # A timeline is "the newest `limit` of something big". Asking for all of it
  # and sorting is linear in the whole history; asking first for the last few
  # hours (a range on `sid`, which the store answers from its index) and
  # widening only if that was too few rows costs what the page costs.
  defp select(clauses, opts) do
    if opts[:order] == :asc do
      select_once(clauses, opts)
    else
      limit = Keyword.get(opts, :limit, @default_limit)
      upper_us = if b = opts[:before], do: Snowflake.to_unix_ms(b) * 1000

      windowed(upper_us, limit, fn lower_us ->
        select_once([sid_range(lower_us, nil) | clauses], opts)
      end)
    end
  end

  # Run `fun` with a lower bound (µs) that widens until it returns `limit` rows.
  defp windowed(upper_us, limit, fun) do
    anchor = upper_us || Graph.now()

    Enum.find_value(@windows_hours, fn hours ->
      lower = if hours, do: anchor - hours * 3_600_000_000
      rows = fun.(lower)
      if length(rows) >= limit or lower == nil, do: rows
    end)
  end

  defp sid_range(lower_us, upper_us) do
    lo = if lower_us, do: "[(>= ?sid #{Snowflake.encode(div(lower_us, 1000), 0)})]", else: ""
    hi = if upper_us, do: "[(< ?sid #{Snowflake.encode(div(upper_us, 1000), 0)})]", else: ""
    "[?o :object/sid ?sid] #{lo} #{hi}"
  end

  defp time_range(var, lower_us, upper_us) do
    [lower_us && "[(>= #{var} #{lower_us})]", upper_us && "[(< #{var} #{upper_us})]"]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" ")
  end

  # Two steps. First only what orders and filters (`sid` and the entity),
  # cut to the page; then the page's columns in one `pull_many`. Fetching
  # every column for every candidate and sorting afterwards costs the
  # candidates, not the page.
  defp select_once(clauses, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    {cmp, dir} = if opts[:order] == :asc, do: {">", ":asc"}, else: {"<", ":desc"}
    cursor = if b = opts[:before], do: "[(#{cmp} ?sid #{b})]", else: ""

    Graph.query!("""
    [:find ?sid ?o
     :where #{Enum.join(clauses, " ")}
            [?o :object/sid ?sid] (not [?o :object/deleted-at _])
            #{cursor}
     :order-by [?sid #{dir}] :limit #{limit}]
    """)
    |> hydrate()
  end

  @selector [
    ":object/id",
    ":object/sid",
    ":object/published",
    ":object/type",
    ":object/content-html",
    ":object/summary",
    ":object/sensitive?",
    ":object/visibility",
    ":object/language",
    %{":object/attributed-to" => [":actor/id"]},
    %{":object/in-reply-to" => [":object/id"]}
  ]

  # `[[sid, eid], …]` (already in page order) → rows.
  defp hydrate([]), do: []

  defp hydrate(found),
    do: found |> Enum.map(fn [_sid, o] -> o end) |> pull() |> Enum.map(&from_pull/1)

  defp pull(eids) do
    {:ok, %{"result" => result}} =
      SukhiFedi.Datalevin.Client.call(Graph.client(), :pull_many, %{
        "selector" => @selector,
        "eids" => eids
      })

    SukhiFedi.Datalevin.Edn.decode(result)
  end

  defp from_pull(m) do
    %{
      id: m[":object/id"],
      sid: m[":object/sid"],
      published: m[":object/published"],
      type: trim_kw(m[":object/type"] || ":Note"),
      author: get_in(m, [":object/attributed-to", ":actor/id"]),
      html: m[":object/content-html"] || "",
      summary: m[":object/summary"] || "",
      sensitive?: m[":object/sensitive?"] || false,
      visibility: trim_kw(m[":object/visibility"] || ":direct"),
      language: m[":object/language"] || "",
      reply_to: get_in(m, [":object/in-reply-to", ":object/id"]),
      via: []
    }
  end

  defp trim_kw(kw), do: String.trim_leading(to_string(kw), ":")

  defp boosts(me, followee, bound, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    found =
      Graph.query!("""
      [:find ?bp ?o ?booster
       :where [?x :activity/published ?bp] #{bound}
              #{me} #{followee}
              [?x :activity/actor ?a] [?x :activity/type :Announce] [?x :activity/object ?o]
              [?a :actor/id ?booster]
              [?o :object/visibility ?vis] [(ground [:public :unlisted]) [?vv ...]] [(= ?vis ?vv)]
              (not [?o :object/deleted-at _])
       :order-by [?bp :desc] :limit #{limit}]
      """)

    rows =
      found
      |> Enum.map(fn [_, o, _] -> o end)
      |> then(&if(&1 == [], do: [], else: pull(&1)))
      |> Enum.map(&from_pull/1)

    Enum.zip_with(rows, found, fn row, [bp, _o, booster] ->
      Map.merge(row, %{via: [booster], at: bp})
    end)
  end

  defp visibilities(opts) do
    vs = Keyword.get(opts, :visibilities, @listed)
    "[(ground [#{Enum.map_join(vs, " ", &":#{&1}")}]) [?v ...]] [?o :object/visibility ?v]"
  end

  defp lit(s), do: Edn.literal(s)
end
