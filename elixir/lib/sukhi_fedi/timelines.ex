# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Timelines do
  @moduledoc """
  Timeline queries for the Mastodon REST surface.

  Returns `Note` rows directly (not `Object` raw_json rows) so the api
  side can render Status JSON via `MastodonStatus.render/1` without
  parsing JSON-LD.

  The `:feeds` addon's Object-based queries are kept for the legacy
  `objects` table aggregation but are not used here. Once inbound AP
  Create(Note) writes a `notes` row in addition to `objects`, both
  paths can converge.
  """

  import Ecto.Query

  alias SukhiFedi.{Repo, Snowflake}
  alias SukhiFedi.Lists
  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Schema.{Account, Boost, Follow, Note, Tag}

  @default_limit 20
  @max_limit 40

  # A boost has no snowflake id of its own — it's a plain `bigserial` row — so
  # the home feed mints a cursor from the boost's `created_at` via
  # `SukhiFedi.Snowflake` (the same layout as a note id). That puts boosts and
  # notes in one time-sortable id space, which is what lets us interleave them
  # and keep id-based (`max_id`/`since_id`) pagination working across both.

  @doc """
  Home timeline: notes from accounts the viewer follows (state=accepted),
  plus the viewer's own notes, interleaved with boosts (reblogs) by those
  same accounts. Newest first. Mastodon pagination opts.

  `:exclude_self` drops the viewer's own notes and boosts — for a surface
  that means "what my friends said" rather than "everything I can see".

  Boosts come back as wrapper maps (`%{__boost__: true, ...}`) carrying the
  booster and the already-enriched boosted note; `MastodonStatus.render`
  turns each into a reblog Status. Notes come back as `%Note{}` as before.
  """
  @spec home(Account.t() | integer(), keyword() | map()) :: [Note.t() | map()]
  def home(%Account{id: id, username: username}, opts \\ []) do
    opts = normalize_opts(opts)
    limit = opts |> Map.get(:limit, @default_limit) |> clamp_limit()

    actor_uri = local_actor_uri(username)
    following_account_ids = following_local_account_ids(actor_uri)

    # Members of an *exclusive* circle are followed (so their posts arrive)
    # but kept out of home — you read them in the circle's own feed. One
    # exception: their *replies to a post on this server* (in_reply_to points
    # back here, ≈ to you) still surface, so a circle member talking to you is
    # never silently dropped from home. Boosts have no reply notion, so circle
    # members stay fully quiet there (boost_account_ids keeps the subtraction).
    excluded = Lists.excluded_account_ids(id)
    reply_here = "https://#{SukhiFedi.Config.domain!()}/%"

    # Per-list home gate: members of a (non-exclusive) *gated* list have their
    # posts narrowed in home — a post must pass every condition of every list
    # that holds the author. only_media members must carry media,
    # hide_sensitive members must be non-sensitive, hide_boosts members' boosts
    # are dropped, hide_replies members' replies are dropped, replies_to_me
    # members' replies must answer a post here, and a keyword member's post
    # must match (applied as the NOT EXISTS gate below, since it varies per
    # list). Everyone else is untouched. (Global opts[:*] filters from the
    # timeline dropdown still apply on top.)
    pl = Lists.home_filter_members(id)

    # Accounts the viewer has blocked or muted drop out of their own home
    # feed (and its boosts). Accounts on a `:silence`-severity instance drop
    # out of *everyone's* feed (operator policy, not per-viewer) — the same
    # id-subtraction, one global set.
    hidden = Moderation.hidden_author_ids(id) ++ Moderation.silenced_author_ids()

    # `:exclude_self` ── 自分の投稿を、自分の読む面から外す。
    #
    # Mastodon の home が自分を抱えているのは、他に置き場が無かった
    # 名残りでもある(出した確認・会話の文脈・振り返り)。natadeco では
    # それぞれに家がある ── 出したことは板で見え、会話の文脈は返信が
    # 親を一段抱えるので読め、振り返りはプロフィール、反応が来たかは
    # 通知。残るのは「反応の付かない自分の投稿を、自分で何度も見る」
    # ことだけなので、外せるようにしておく。
    mine = if opts[:exclude_self], do: [], else: [id]

    note_account_ids = mine ++ (following_account_ids -- hidden)
    boost_account_ids = mine ++ (following_account_ids -- excluded -- pl.hide_boosts -- hidden)

    notes =
      Note
      |> where([n], n.account_id in ^note_account_ids)
      |> where([n], n.account_id not in ^excluded or like(n.in_reply_to_ap_id, ^reply_here))
      |> where([n], n.visibility in ^SukhiFedi.Visibility.not_direct())
      |> where(
        [n],
        n.account_id not in ^pl.only_media or
          fragment("EXISTS (SELECT 1 FROM note_media nm WHERE nm.note_id = ?)", n.id)
      )
      |> where(
        [n],
        n.account_id not in ^pl.hide_sensitive or (n.sensitive == false and is_nil(n.cw))
      )
      |> where([n], n.account_id not in ^pl.hide_replies or is_nil(n.in_reply_to_ap_id))
      |> where(
        [n],
        n.account_id not in ^pl.replies_to_me or is_nil(n.in_reply_to_ap_id) or
          like(n.in_reply_to_ap_id, ^reply_here)
      )
      # Keyword gate: a post from an author who sits in a keyword-carrying
      # (non-exclusive) list of the viewer's must match that keyword — in its
      # content, or as a hashtag when the keyword leads with `#`. Each such
      # list is its own constraint (a violation is a missed keyword), so a post
      # is dropped if *any* containing keyword list goes unmatched.
      |> where(
        [n],
        fragment(
          "NOT EXISTS (SELECT 1 FROM list_accounts la JOIN lists l ON l.id = la.list_id WHERE l.account_id = ? AND l.exclusive = false AND la.account_id = ? AND COALESCE(l.filter_keyword, '') <> '' AND NOT (? ILIKE '%' || l.filter_keyword || '%' OR EXISTS (SELECT 1 FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = ? AND t.name = lower(ltrim(l.filter_keyword, '#')))))",
          ^id,
          n.account_id,
          n.content,
          n.id
        )
      )
      |> maybe_only_media(opts[:only_media])
      |> maybe_hide_sensitive(opts[:hide_sensitive])
      |> apply_paging(opts)
      |> Repo.all()
      |> Repo.preload([:account, :media, :tags])
      |> SukhiFedi.Notes.with_refs(id)

    # RT(ブースト)を隠すフィルタ。home だけがブーストを混ぜるので、ここで止める。
    # per-list の hide_boosts メンバーは boost_account_ids から既に引いてある。
    boosts =
      if opts[:hide_boosts], do: [], else: home_boosts(boost_account_ids, opts, limit, id)

    # Both notes (id) and boost wrappers (synthesized id) share one
    # time-sortable id space, so a plain id-desc merge is chronological.
    (notes ++ boosts)
    |> Enum.sort_by(& &1.id, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Boosts made by a single account, wrapped as reblog rows for that
  account's profile timeline. Same visibility/cursor/paging rules as the
  home feed (it's `home_boosts` over a one-account list), so a profile and
  the home feed agree on what a boost looks like and how it pages.
  """
  @spec account_boosts(integer(), map(), integer(), integer() | nil) :: [map()]
  def account_boosts(account_id, opts, limit, viewer_id),
    do: home_boosts([account_id], opts, limit, viewer_id)

  # Boosts by `account_ids`, wrapped for the reblog render. Only reblogs of
  # public/unlisted notes surface — a followers-only or direct note must not
  # leak into the home feed via someone else's boost. Paged in the same
  # id space as notes (see `@snowflake_epoch_ms`).
  defp home_boosts(account_ids, opts, limit, viewer_id) do
    # A boost carries its boosted note's author into the feed too, so drop
    # boosts of anyone the viewer has muted or blocked — the same authors
    # whose own notes are already hidden — plus anyone on a silenced instance.
    # (A muted *booster* is filtered upstream via `account_ids`; this closes
    # the other door, where someone the viewer follows boosts a muted or
    # silenced account's post.)
    hidden = Moderation.hidden_author_ids(viewer_id) ++ Moderation.silenced_author_ids()

    # The boosted `Note` is a joined (non-leading) binding here, so the
    # visibility rules — hidden authors, public/unlisted — apply as `where`s
    # on `n` rather than through the pipe form.
    rows =
      from(b in Boost,
        join: n in Note,
        on: n.id == b.note_id,
        join: ba in Account,
        on: ba.id == b.account_id,
        where: b.account_id in ^account_ids,
        where: n.account_id not in ^hidden,
        where: n.visibility in ^SukhiFedi.Visibility.public_only(),
        order_by: [desc: b.created_at],
        limit: ^limit,
        select: %{boost_id: b.id, created_at: b.created_at, booster: ba, note: n}
      )
      |> boost_time_bounds(opts)
      |> Repo.all()

    enriched =
      rows
      |> Enum.map(& &1.note)
      |> Repo.preload([:account, :media, :tags])
      |> SukhiFedi.Notes.with_refs(viewer_id)

    rows
    |> Enum.zip(enriched)
    |> Enum.map(fn {row, note} ->
      %{
        __boost__: true,
        id: boost_cursor(row.created_at, row.boost_id),
        boost_id: row.boost_id,
        created_at: row.created_at,
        account: row.booster,
        note: note
      }
    end)
    |> boost_exact_paging(opts)
  end

  # Mint a note-id-compatible cursor for a boost from its timestamp.
  defp boost_cursor(%DateTime{} = created_at, boost_id),
    do: Snowflake.encode(DateTime.to_unix(created_at, :millisecond), boost_id)

  # DB-side pre-filter: bound `created_at` by the millisecond a cursor encodes
  # (inclusive, since the 16-bit counter tail is resolved exactly in Elixir by
  # `boost_exact_paging`). Cheap and keeps the fetched set to one page.
  defp boost_time_bounds(query, opts) do
    query
    |> maybe_boost_upper(opts[:max_id])
    |> maybe_boost_lower(opts[:since_id] || opts[:min_id])
  end

  defp maybe_boost_upper(q, nil), do: q

  defp maybe_boost_upper(q, max_id) when is_integer(max_id),
    do: where(q, [b], b.created_at <= ^Snowflake.to_datetime(max_id))

  defp maybe_boost_lower(q, nil), do: q

  defp maybe_boost_lower(q, since_id) when is_integer(since_id),
    do: where(q, [b], b.created_at >= ^Snowflake.to_datetime(since_id))

  # Exact cursor comparison on the synthesized ids (the DB bound was inclusive).
  defp boost_exact_paging(wrappers, opts) do
    wrappers
    |> filter_cursor(opts[:max_id], fn id, c -> c < id end)
    |> filter_cursor(opts[:since_id] || opts[:min_id], fn id, c -> c > id end)
  end

  defp filter_cursor(wrappers, nil, _cmp), do: wrappers

  defp filter_cursor(wrappers, id, cmp) when is_integer(id),
    do: Enum.filter(wrappers, fn w -> cmp.(id, w.id) end)

  @doc """
  Public timeline: every public-visibility note authored by a local
  account. Remote posts (`accounts.domain IS NOT NULL`) are excluded
  by default; pass `local: false` to include them once the federated
  TL is exposed.

  Opts: `:max_id`, `:since_id`, `:min_id`, `:limit`, `:local`
  (default `true`), `:only_media`.
  """
  @spec public(keyword() | map()) :: [Note.t()]
  def public(opts \\ []) do
    opts = normalize_opts(opts)
    local? = Map.get(opts, :local, true)

    # Silenced instances stay off public too, for everyone (anonymous
    # included). The default `local: true` already drops remote authors, so
    # this only bites the federated TL (`local: false`); the rule lives in
    # `Moderation.silenced_author_ids/0` either way.
    silenced = Moderation.silenced_author_ids()

    Note
    |> where([n], n.visibility == "public")
    |> where([n], n.account_id not in ^silenced)
    |> maybe_local_only(local?)
    |> apply_paging(opts)
    |> maybe_only_media(opts[:only_media])
    |> maybe_hide_sensitive(opts[:hide_sensitive])
    |> Repo.all()
    |> Repo.preload([:account, :media, :tags])
    |> SukhiFedi.Notes.with_refs()
  end

  @doc """
  Bubble (ご近所) timeline: public-visibility *remote* notes from the small
  admin-curated set of trusted instances (`Moderation.bubble_domains/0`).
  Newest first. A subtractive, curated feed — an empty allow-set means an
  empty bubble, never the firehose.

  Reuses the public timeline's filters/paging; just narrows the origin to the
  allowed domains. `viewer_id` (optional) lets a logged-in reader's own
  blocks/mutes drop out via `Moderation.hidden_author_ids/1`, the same
  id-subtraction every feed uses.

  Opts: `:max_id`, `:since_id`, `:min_id`, `:limit`, `:only_media`,
  `:hide_sensitive`, `:viewer_id`.
  """
  @spec bubble(keyword() | map()) :: [Note.t()]
  def bubble(opts \\ []) do
    opts = normalize_opts(opts)
    viewer_id = Map.get(opts, :viewer_id)

    # The allow-set is the one gate (Moderation.bubble_domains/0). A trusted
    # instance that's also silenced still drops out — silence wins, same set
    # public/home subtract — and a viewer's own blocks/mutes drop out too.
    allowed = Moderation.bubble_domains()
    hidden = Moderation.hidden_author_ids(viewer_id) ++ Moderation.silenced_author_ids()

    # `notes.domain IN allowed` already excludes local notes (NULL domain),
    # so this is the local-notes negation for the bubble: remote-only by
    # construction, no separate `local: false` toggle.
    Note
    |> where([n], n.visibility == "public" and n.domain in ^allowed)
    |> where([n], n.account_id not in ^hidden)
    |> maybe_only_media(opts[:only_media])
    |> maybe_hide_sensitive(opts[:hide_sensitive])
    |> apply_paging(opts)
    |> Repo.all()
    |> Repo.preload([:account, :media, :tags])
    |> SukhiFedi.Notes.with_refs(viewer_id)
  end

  # Local-origin notes carry no `ap_id` (it's synthesized on demand), so a
  # mirrored remote post always has one. Filtering on that is equivalent to
  # joining the author and checking `accounts.domain IS NULL`, but drops the
  # join. `SukhiFedi.Notes.local_notes/1` is the shared origin predicate.
  defp maybe_local_only(query, true), do: SukhiFedi.Notes.local_notes(query)

  defp maybe_local_only(query, _), do: query

  @doc """
  Hashtag timeline: public notes tagged with `hashtag` (lower-cased,
  no leading `#`).

  Opts: `:max_id`, `:since_id`, `:min_id`, `:limit`, `:local` (default true).
  """
  @spec tag(String.t(), keyword() | map()) :: [Note.t()]
  def tag(hashtag, opts \\ []) when is_binary(hashtag) do
    opts = normalize_opts(opts)
    local? = Map.get(opts, :local, true)
    name = hashtag |> String.trim_leading("#") |> String.downcase()

    base =
      from(n in Note,
        join: nt in "note_tags",
        on: nt.note_id == n.id,
        join: t in Tag,
        on: t.id == nt.tag_id,
        where: t.name == ^name and n.visibility == "public"
      )

    base
    |> maybe_local_only(local?)
    |> maybe_only_media(opts[:only_media])
    |> maybe_hide_sensitive(opts[:hide_sensitive])
    |> apply_paging(opts)
    |> Repo.all()
    |> Repo.preload([:account, :media, :tags])
    |> SukhiFedi.Notes.with_refs()
  end

  # ── paging ───────────────────────────────────────────────────────────────

  defp apply_paging(query, opts) do
    limit =
      opts
      |> Map.get(:limit, @default_limit)
      |> clamp_limit()

    query
    |> maybe_max_id(opts[:max_id])
    |> maybe_since_id(opts[:since_id])
    |> maybe_min_id(opts[:min_id])
    |> order_by([n], desc: n.id)
    |> limit(^limit)
  end

  defp maybe_max_id(q, nil), do: q
  defp maybe_max_id(q, v) when is_integer(v), do: where(q, [n], n.id < ^v)

  defp maybe_since_id(q, nil), do: q
  defp maybe_since_id(q, v) when is_integer(v), do: where(q, [n], n.id > ^v)

  defp maybe_min_id(q, nil), do: q
  defp maybe_min_id(q, v) when is_integer(v), do: where(q, [n], n.id > ^v)

  defp maybe_only_media(q, true),
    do: where(q, [n], fragment("EXISTS (SELECT 1 FROM note_media nm WHERE nm.note_id = ?)", n.id))

  defp maybe_only_media(q, _), do: q

  # センシティブ / CW 付きを隠す。sensitive フラグと cw(spoiler)どちらも無い
  # ものだけ残す。
  defp maybe_hide_sensitive(q, true),
    do: where(q, [n], n.sensitive == false and is_nil(n.cw))

  defp maybe_hide_sensitive(q, _), do: q

  defp clamp_limit(n) when is_integer(n) and n > 0 and n <= @max_limit, do: n
  defp clamp_limit(_), do: @default_limit

  # ── helpers ──────────────────────────────────────────────────────────────

  defp following_local_account_ids(actor_uri) do
    from(f in Follow,
      join: a in Account,
      on: a.id == f.followee_id,
      where: f.follower_uri == ^actor_uri and f.state == "accepted",
      select: a.id
    )
    |> Repo.all()
  end

  defp local_actor_uri(username) do
    domain = SukhiFedi.Config.domain!()
    "https://#{domain}/users/#{username}"
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
end
