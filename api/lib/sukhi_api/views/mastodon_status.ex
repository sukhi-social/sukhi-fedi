# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.MastodonStatus do
  @moduledoc """
  Render a `Note` (or hydrated map) into Mastodon Status JSON.

  Counts and viewer-context flags are passed in via the second
  argument:

      MastodonStatus.render(note, %{
        counts: %{replies: int, reblogs: int, favourites: int},
        viewer: %{favourited: bool, reblogged: bool, bookmarked: bool, pinned: bool},
        reactions: [%{name: "🦊", count: 3, me: false}, ...]
      })

  All keys are optional; missing fields default to `0` / `false` / `[]`.
  Capabilities should batch-fetch via
  `SukhiFedi.Notes.{counts_for_notes, viewer_flags_many,
  reactions_for_notes}` and pass the per-note submap on render.
  """

  alias SukhiApi.Views.{Id, MastodonAccount, MastodonMedia, MastodonPoll}

  @spec render(map() | nil, map()) :: map() | nil
  def render(note, ctx \\ %{})
  def render(nil, _ctx), do: nil

  # A boost wrapper from `Timelines.home` (`%{__boost__: true, ...}`): a reblog
  # Status whose `account` is the booster and whose `reblog` is the boosted
  # note. The booster contributes no content of its own, so the outer shell is
  # empty and `ctx` (reactions etc.) flows down to the inner render.
  def render(%{__boost__: true} = boost, ctx) do
    inner = render(Map.get(boost, :note), ctx)
    build_reblog(boost, inner)
  end

  def render(note, ctx) do
    counts = Map.get(ctx, :counts, %{})
    viewer = Map.get(ctx, :viewer, %{})

    # Mastodon spec の `uri` は「常に文字列」。Moshidon など
    # Kotlin/Gson クライアントは non-null String で受けるので、
    # `ap_id` が未設定だった瞬間に NPE で落ちる。ローカル発の
    # note には `https://<domain>/users/<user>/notes/<id>` を
    # 推測フォールバックとして組み立てる。
    uri = Map.get(note, :ap_id) || derived_uri(note)

    %{
      id: Id.encode(note.id),
      created_at: format_dt(Map.get(note, :created_at)),
      in_reply_to_id: encode_id(Map.get(note, :in_reply_to_id)),
      in_reply_to_account_id: encode_id(Map.get(note, :in_reply_to_account_id)),
      # The real NSFW flag, or implied by a content warning (Mastodon marks
      # a CW'd post sensitive too).
      sensitive: !!Map.get(note, :sensitive) or (Map.get(note, :cw) not in [nil, ""]),
      spoiler_text: Map.get(note, :cw) || "",
      visibility: mastodon_visibility(Map.get(note, :visibility)),
      language: nil,
      uri: uri,
      url: uri,
      replies_count: Map.get(counts, :replies, 0),
      reblogs_count: Map.get(counts, :reblogs, 0),
      favourites_count: Map.get(counts, :favourites, 0),
      edited_at: nil,
      content: render_content(note),
      # Sukhi extension: the verbatim MFM source for a Misskey-family note
      # (nil for a local post or a non-Misskey remote one). Mastodon clients
      # ignore the unknown key; our web client renders the static MFM subset
      # from it instead of the flattened `content` HTML.
      mfm: Map.get(note, :mfm),
      # Sukhi extension: an Article's bare title (nil for a plain Note).
      # The same title is also folded into `content` as a leading <h2> for
      # Mastodon clients; our web client reads this key to route the post
      # to its reader page and to set the page <title>.
      title: Map.get(note, :title),
      reblog: nil,
      # Quote post (Fedibird-compatible): the quoted status nested one
      # level deep. nil when there's no quote or we don't hold the quoted
      # note locally yet.
      quote: render_quote(note),
      application: nil,
      account: render_account(note),
      media_attachments: render_media(note),
      mentions: [],
      tags: render_tags(note),
      emojis: Map.get(note, :emojis) || [],
      card: render_card(Map.get(ctx, :card)),
      poll: render_poll(note),
      pinned: Map.get(viewer, :pinned, false),
      bookmarked: Map.get(viewer, :bookmarked, false),
      favourited: Map.get(viewer, :favourited, false),
      reblogged: Map.get(viewer, :reblogged, false),
      muted: false,
      # Sukhi extension. Pleroma-compatible shape: list of
      # %{name, count, me, url, static_url}. Mastodon clients ignore
      # the unknown key; Sukhi web reads it for reaction chips.
      reactions: Map.get(ctx, :reactions, [])
    }
  end

  @doc """
  Render a list of notes, looking up per-note counts/viewer-flags
  from the supplied maps (each keyed by note id).
  """
  @spec render_list([map()], map(), map(), map()) :: [map()]
  def render_list(
        notes,
        counts_by_id \\ %{},
        viewer_by_id \\ %{},
        reactions_by_id \\ %{},
        cards_by_id \\ %{}
      )
      when is_list(notes) do
    Enum.map(notes, fn n ->
      # For a boost wrapper, key the context off the boosted note's id so the
      # reblog's reactions/counts land on the inner status, not the wrapper.
      key = context_key(n)

      render(n, %{
        counts: Map.get(counts_by_id, key, %{}),
        viewer: Map.get(viewer_by_id, key, %{}),
        reactions: Map.get(reactions_by_id, key, []),
        card: Map.get(cards_by_id, key)
      })
    end)
  end

  @doc """
  The id a feed item's hydration context is keyed by: a boost wrapper borrows
  its boosted note's id, a plain note uses its own. Callers batch-fetch
  reactions/counts against these ids.
  """
  @spec context_key(map()) :: integer() | nil
  def context_key(%{__boost__: true, note: %{id: id}}), do: id
  def context_key(%{id: id}), do: id

  # The reblog wrapper Status. Mirrors the inner status's visibility, carries no
  # body of its own, and nests the boosted note under `reblog`.
  defp build_reblog(boost, inner) do
    booster = Map.get(boost, :account)
    uri = reblog_uri(booster, Map.get(boost, :boost_id))

    %{
      id: Id.encode(Map.get(boost, :id)),
      created_at: format_dt(Map.get(boost, :created_at)),
      in_reply_to_id: nil,
      in_reply_to_account_id: nil,
      sensitive: false,
      spoiler_text: "",
      visibility: (inner && inner.visibility) || "public",
      language: nil,
      uri: uri,
      url: uri,
      replies_count: 0,
      reblogs_count: 0,
      favourites_count: 0,
      edited_at: nil,
      content: "",
      reblog: inner,
      quote: nil,
      application: nil,
      account: render_booster(booster),
      media_attachments: [],
      mentions: [],
      tags: [],
      emojis: [],
      card: nil,
      poll: nil,
      pinned: false,
      bookmarked: false,
      favourited: false,
      reblogged: false,
      muted: false,
      reactions: []
    }
  end

  defp render_booster(account) when is_map(account), do: MastodonAccount.render(account, %{})
  defp render_booster(_), do: MastodonAccount.render(%{id: 0, username: "unknown"}, %{})

  defp reblog_uri(%{username: u}, boost_id) when is_binary(u) do
    domain = SukhiApi.Config.domain!()
    "https://#{domain}/users/#{u}/statuses/#{boost_id}/activity"
  end

  defp reblog_uri(_, boost_id) do
    domain = SukhiApi.Config.domain!()
    "https://#{domain}/statuses/#{boost_id}/activity"
  end

  defp encode_id(nil), do: nil
  defp encode_id(id), do: Id.encode(id)

  # `poll_view` is the `Polls.get_with_results/2` map the gateway attaches
  # in `Notes.with_refs/2`. nil (no poll) renders as the spec's `poll: null`.
  # FEP-8967 link preview card. The hydration layer hands us the stored
  # card (or nil) in `ctx.card`; we shape it to Mastodon's card entity.
  defp render_card(nil), do: nil

  defp render_card(%{} = c) do
    %{
      url: c.url,
      title: c.title || "",
      description: c.description || "",
      type: c.type || "link",
      image: Map.get(c, :image),
      provider_name: c.provider_name || "",
      provider_url: "",
      author_name: "",
      author_url: "",
      html: "",
      width: 0,
      height: 0,
      embed_url: "",
      blurhash: nil
    }
  end

  defp render_poll(note) do
    case Map.get(note, :poll_view) do
      %{poll: _} = view -> MastodonPoll.render(view)
      _ -> nil
    end
  end

  # The quoted status, rendered one level deep. The quoted note carries
  # no `:quoted_note` of its own (gateway only enriches the top level),
  # so the nested render's own `quote` resolves to nil — no recursion.
  defp render_quote(note) do
    case Map.get(note, :quoted_note) do
      %{} = quoted -> if Map.get(quoted, :id), do: render(quoted, %{}), else: nil
      _ -> nil
    end
  end

  # Our notes store the AP-flavoured "followers"; Mastodon's StatusPrivacy
  # enum calls that "private". A Gson client (Moshidon) rejects the whole
  # status when `visibility` isn't one of its four known values, so map it
  # and fall back to "public" for anything unexpected.
  defp mastodon_visibility("followers"), do: "private"
  defp mastodon_visibility(v) when v in ["public", "unlisted", "private", "direct"], do: v
  defp mastodon_visibility(_), do: "public"

  defp render_content(note) do
    # A local note carries its rendered form (Markdown, line breaks and all);
    # a remote one carries the HTML its server sent. Either way `content_html`
    # first, `content` behind it — the fallback is what keeps remote notes and
    # anything written before the column existed rendering as they always did.
    raw = Map.get(note, :content_html) || Map.get(note, :content) || ""
    html = if String.starts_with?(raw, "<"), do: raw, else: "<p>#{raw}</p>"

    # When we're showing the quoted post as a card (render_quote/1), a
    # trailing "RE: <link>" in the body is the same reference twice over.
    # Sharkey/Firefish/Fedibird append it for Mastodon's sake (Mastodon
    # keeps it — it never strips the body); since we render the card, we
    # drop the redundant tail. We only strip when the card is actually
    # there, so a quote we couldn't fetch keeps its one link.
    html = if has_quote_card?(note), do: strip_quote_reference(html), else: html

    localize_hashtags(html)
  end

  # Remote posts carry hashtag links that point back at the origin server
  # (e.g. https://misskey.io/tags/foo). Repoint them at our own tag
  # timeline so a tag stays inside this instance — the same thing Mastodon
  # does on the way in. We key off rel="tag" (the hashtag marker) and reuse
  # the existing /tags/<name> URL scheme our `tags` array already serves.
  @anchor ~r{<a\b[^>]*>}i
  @rel_tag ~r/rel="[^"]*\btag\b[^"]*"/i
  @href ~r/href="([^"]*)"/i

  defp localize_hashtags(html) do
    Regex.replace(@anchor, html, fn open ->
      with true <- Regex.match?(@rel_tag, open),
           [href] <- Regex.run(@href, open, capture: :all_but_first) do
        name = href |> String.split("/") |> List.last() |> URI.decode()
        local = "https://#{SukhiApi.Config.domain!()}/tags/#{name}"
        String.replace(open, ~s(href="#{href}"), ~s(href="#{local}"))
      else
        _ -> open
      end
    end)
  end

  defp has_quote_card?(note) do
    case Map.get(note, :quoted_note) do
      %{} = quoted -> !!Map.get(quoted, :id)
      _ -> false
    end
  end

  # hackers.pub (Fedify) wraps the reference in <span class="quote-inline">,
  # an explicit marker we can lift out whole. Sharkey/Firefish/Fedibird
  # instead give a bare "RE:"/"QT:" label + link — the label is the strong
  # signal it's a quote reference rather than a link the author meant to
  # keep. Either way we only ever touch the very end of the body, in two
  # shapes: the reference on its own paragraph, or tacked onto the last one.
  @quote_patterns [
    # hackers.pub span, on its own paragraph → drop the paragraph
    {~r{\s*<p>\s*<span\b[^>]*\bquote-inline\b[^>]*>.*?</span>\s*</p>\s*\z}is, ""},
    # hackers.pub span, tail of the last paragraph → keep the </p>
    {~r{(?:<br\s*/?>\s*)*<span\b[^>]*\bquote-inline\b[^>]*>.*?</span>\s*</p>\s*\z}is, "</p>"},
    # bare RE:/QT: label on its own paragraph
    {~r{\s*<p>\s*(?:RE|QT):\s*<a\b[^>]*>.*?</a>\s*</p>\s*\z}is, ""},
    # bare RE:/QT: label tacked onto the last paragraph after a <br>
    {~r{(?:<br\s*/?>\s*)+(?:RE|QT):\s*<a\b[^>]*>.*?</a>\s*</p>\s*\z}is, "</p>"}
  ]

  defp strip_quote_reference(html) do
    Enum.find_value(@quote_patterns, html, fn {re, replacement} ->
      Regex.match?(re, html) && Regex.replace(re, html, replacement)
    end)
  end

  defp render_account(note) do
    account = Map.get(note, :account)

    if is_map(account) and Map.has_key?(account, :username) do
      MastodonAccount.render(account, %{})
    else
      # spec 上 `account` も非 null。ハイドレートし忘れた経路から
      # うっかり nil が漏れると、Moshidon など Kotlin/Gson 系で
      # NPE になる。username 不明でも plausible な形を返して
      # クラッシュさせない。 [[mastodon_account.render の空 fallback と対]]
      MastodonAccount.render(
        %{id: Map.get(note, :account_id) || 0, username: "unknown"},
        %{}
      )
    end
  end

  defp render_media(note) do
    case Map.get(note, :media) do
      media when is_list(media) -> Enum.map(media, &MastodonMedia.render/1)
      _ -> []
    end
  end

  defp render_tags(note) do
    domain = SukhiApi.Config.domain!()

    case Map.get(note, :tags) do
      tags when is_list(tags) ->
        Enum.map(tags, fn t ->
          %{name: t.name, url: "https://#{domain}/tags/#{t.name}"}
        end)

      _ ->
        []
    end
  end

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(_), do: nil

  # ap_id が落ちているときの最後の砦。account がぶら下がっていれば
  # そこから username を拾って `users/<u>/notes/<id>` を組む。それも
  # 無ければ `notes/<id>` だけでも返す ─ 形式が崩れていても non-null
  # の文字列であることが優先。
  defp derived_uri(note) do
    domain = SukhiApi.Config.domain!()
    id = Map.get(note, :id)

    case Map.get(note, :account) do
      %{username: u} when is_binary(u) ->
        "https://#{domain}/users/#{u}/notes/#{id}"

      _ ->
        "https://#{domain}/notes/#{id}"
    end
  end
end
