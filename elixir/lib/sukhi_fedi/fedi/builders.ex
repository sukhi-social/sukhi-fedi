# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.Builders do
  @moduledoc """
  Builds outbound ActivityPub JSON-LD from the domain payloads the
  delivery node sends to `fedify.translate.v1` — the native port of
  `bun/handlers/build/*.ts`, with the same payload contracts and the
  same result envelopes (`{"note": …, "recipientInboxes": …}` etc.).

  Order of operations is preserved from the Bun version: build the core
  activity → LD-sign it → inject the compatibility extras
  (`_misskey_content`, quote aliases, attachments). The extras land
  *after* signing, exactly as before, so receivers see byte-compatible
  semantics. (Yes, that means the LD signature does not cover them —
  a pre-existing tradeoff; direct delivery is authenticated by the
  HTTP signature.)

  The FEP-8b32 Object Integrity Proof joins in fedify's order where it
  can: proof first, LD signature over it, so Mastodon-family receivers
  (which canonicalize everything but `signature`) still verify the
  LD-sig, and fedify-family receivers (which strip `signature` and
  `proof`) verify the proof. note/dm are the exception — their extras
  land after the LD signature and the proof must cover what's actually
  delivered, so there the proof comes last and the LD signature stays
  exactly as uncovering as it already was.
  """

  alias SukhiFedi.Fedi.{Audience, JWK, LdSignature, Oip}

  # One shared @context for everything we emit. AS + security/v1 (for
  # the signature terms) + the handful of compatibility terms our
  # injected fields use, so strict JSON-LD consumers don't drop them.
  @context [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/v1",
    # Defines the `proof` member (FEP-8b32), so it expands instead of
    # being dropped — and is therefore covered by the LD signature when
    # the proof is attached before signing.
    "https://w3id.org/security/data-integrity/v1",
    # FEP-044f quote posts ride a GtS-flavoured interaction policy:
    # `interactionPolicy`, `canQuote`, `automaticApproval`,
    # `manualApproval`, `interactingObject`, `interactionTarget`. This
    # context is vendored by Canon.ContextLoader, so expansion (and
    # therefore LD-signing) never reaches for the network.
    "https://gotosocial.org/ns",
    %{
      "toot" => "http://joinmastodon.org/ns#",
      "misskey" => "https://misskey-hub.net/ns#",
      "sensitive" => "as:sensitive",
      "Hashtag" => "as:Hashtag",
      "Emoji" => "toot:Emoji",
      "_misskey_content" => "misskey:_misskey_content",
      # FEP-044f canonical quote vocabulary. Defined *after*
      # gotosocial.org/ns so these win over its gts: aliases — Mastodon
      # and fedify read the fep/044f terms.
      "quote" => %{"@id" => "https://w3id.org/fep/044f#quote", "@type" => "@id"},
      "quoteUrl" => "as:quoteUrl",
      "_misskey_quote" => "misskey:_misskey_quote",
      "QuoteAuthorization" => "https://w3id.org/fep/044f#QuoteAuthorization",
      "QuoteRequest" => "https://w3id.org/fep/044f#QuoteRequest",
      "quoteAuthorization" => %{
        "@id" => "https://w3id.org/fep/044f#quoteAuthorization",
        "@type" => "@id"
      }
    }
  ]

  # We let anyone quote our public posts, and approve their requests
  # automatically (FEP-044f). Advertising the policy is what tells a
  # Mastodon-family peer it may send us a `QuoteRequest` and expect a
  # `QuoteAuthorization` back, so the quote renders inline rather than
  # as a bare link.
  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @quote_policy %{"canQuote" => %{"automaticApproval" => [@as_public]}}

  @doc """
  Dispatches a `fedify.translate.v1` request. Returns the same result
  envelope the Bun handler for that `object_type` returned.
  """
  @spec build(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def build("note", p), do: note(p)
  def build("update", p), do: update(p)
  def build("vote", p), do: vote(p)
  def build("dm", p), do: dm(p)
  def build("follow", p), do: follow(p)
  def build("quote_request", p), do: quote_request(p)
  def build("announce", p), do: announce(p)
  def build("like", p), do: like(p)
  def build("emoji_react", p), do: emoji_react(p)
  def build("undo", p), do: undo(p)
  def build("delete", p), do: delete(p)
  def build("move", p), do: move(p)
  def build("add", p), do: collection_op("Add", p)
  def build("remove", p), do: collection_op("Remove", p)
  def build(other, _p), do: {:error, "unknown object_type: #{other}"}

  # ── Builders ─────────────────────────────────────────────────────────────

  defp note(p) do
    audience = Audience.public(p["actor"])
    activity = wrap_create(p, note_object(p, audience), audience)
    finalize_note(activity, p, "note")
  end

  # FEP-044f: re-deliver a note as an `Update` once a quote authorization
  # lands (or is withdrawn), so followers' servers refresh the inline
  # quote. Same object + post-sign injections as a fresh note; only the
  # envelope and the `updated` stamp differ.
  defp update(p) do
    audience = Audience.public(p["actor"])
    object = Map.put(note_object(p, audience), "updated", now())

    activity = %{
      "@context" => @context,
      "id" => p["activityId"],
      "type" => "Update",
      "actor" => p["actor"],
      "to" => audience.to,
      "cc" => audience.cc,
      "object" => object
    }

    finalize_note(activity, p, "update")
  end

  # The Note object shared by `note/1` (Create) and `update/1` (Update).
  defp note_object(p, audience) do
    %{
      "id" => p["noteId"],
      "type" => object_type(p),
      "attributedTo" => p["actor"],
      "content" => titled_content(p),
      "published" => p["published"] || now(),
      "to" => audience.to,
      "cc" => audience.cc
    }
    |> put_if("inReplyTo", p["inReplyToId"])
    # The author's content warning (AP `summary`) and sensitive flag were
    # never carried before, so remotes rendered CW'd / NSFW posts unwarned.
    # 題。掲示板を持つ実装(NodeBB / PieFed / Lemmy)はここを読む。
    # Mastodon は `Note` の `name` を一度も読まないので、向こうで題が
    # 消える ── だから題は本文の頭にも引用として置く(`titled_content/1`)。
    |> put_if("name", p["title"])
    |> put_if("summary", summary_for(p))
    |> put_if("sensitive", p["sensitive"])
    # FEP-044f canonical `quote` (signed), plus the authorization stamp
    # once the quoted author granted it. The Misskey aliases + FEP-e232
    # tag are still injected post-sign (`inject_quote`).
    |> put_if("quote", p["quoteUrl"])
    |> put_if("quoteAuthorization", p["quoteAuthorization"])
    |> Map.put("interactionPolicy", @quote_policy)
  end

  # 既定は `Note`。`Article` は書いた人が選んだときだけ。
  #
  # 意味の上では題を持つものは `Article` だが、Mastodon は `Article` を
  # CONVERTED_TYPES に入れていて、`content` を一行も出さない ── 題と
  # summary とリンクだけになる。長い文章なら「続きはリンク先で」が
  # 自然だが、一行の書き込みでそれをやると、外の人には何も届かない。
  # だから選べるものにして、既定は Note にした。
  defp object_type(p), do: if(p["asArticle"] && titled?(p), do: "Article", else: "Note")

  defp titled?(p), do: is_binary(p["title"]) and p["title"] != ""

  # `Article` の `summary` は、Mastodon では本文の代わりに出る場所
  # (CONVERTED_TYPES の `processed_text` が題・summary・リンクを並べる)。
  # 空のままだと題とリンクだけになるので、本文の書き出しを入れておく ──
  # 選んだ人が思っているより何も伝わらない、を避けるため。
  #
  # 自分で CW を書いている人のぶんは触らない。それはその人の言葉で、
  # 抜粋で上書きしていいものではない。
  defp summary_for(p) do
    cond do
      is_binary(p["summary"]) and p["summary"] != "" -> p["summary"]
      p["asArticle"] && titled?(p) -> excerpt(p["content"])
      true -> p["summary"]
    end
  end

  @excerpt_len 220

  defp excerpt(html) when is_binary(html) do
    text =
      html
      |> String.replace(~r{<[^>]*>}, " ")
      |> String.replace(~r{\s+}, " ")
      |> String.trim()

    if String.length(text) > @excerpt_len,
      do: String.slice(text, 0, @excerpt_len) <> "…",
      else: text
  end

  defp excerpt(_), do: nil

  # 題つきの投稿は、本文の頭に「> 題 — @書いた人」を引用で置く。
  #
  # 保存する本文には入れない ── natadeco の画面は題も名前ももう出して
  # いるので、そこで二度読ませない。ここ(線の上)だけで足りる。外では
  # 題が本文の外に無い(Mastodon は `name` を読まない)し、ブーストされて
  # 文脈から離れたときも、これが付いていれば何の話か分かる。
  defp titled_content(p) do
    case p["title"] do
      t when is_binary(t) and t != "" -> title_header(t, p) <> (p["content"] || "")
      _ -> p["content"]
    end
  end

  defp title_header(title, p) do
    who =
      case {p["authorHandle"], p["authorUri"]} do
        {h, u} when is_binary(h) and is_binary(u) ->
          " — <a href=\"#{esc(u)}\" class=\"mention\">#{esc(h)}</a>"

        _ ->
          ""
      end

    "<blockquote><p>#{esc(title)}#{who}</p></blockquote>"
  end

  defp esc(s) do
    s
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # 頭に置いた `@handle` を、本物の Mention にする。付けないと向こうでは
  # ただの文字で、押しても誰にも行き着かない。
  #
  # 自分宛てなので通知は増えない ── `Notes.Create.notify_local_mentions/1`
  # は自分を弾くし、向こうから見れば書いた人は remote。
  defp inject_author_mention(activity, %{"title" => t, "authorHandle" => h, "authorUri" => u})
       when is_binary(t) and t != "" and is_binary(h) and is_binary(u) do
    update_object(activity, fn object ->
      tags = List.wrap(object["tag"] || [])
      Map.put(object, "tag", tags ++ [%{"type" => "Mention", "href" => u, "name" => h}])
    end)
  end

  defp inject_author_mention(activity, _), do: activity

  # Sign → post-sign compatibility injections → FEP-8b32 proof, then wrap
  # under `key` ("note" for Create, "update" for Update). The injections
  # land after the LD signature (parity with the historical Bun path); the
  # proof covers them because it attaches last.
  defp finalize_note(activity, p, key) do
    with {:ok, signed} <- sign(p, activity),
         injected =
           signed
           |> inject_misskey_content(titled_content(p))
           |> inject_quote(p["quoteUrl"])
           |> inject_attachments(p["attachments"])
           |> inject_author_mention(p),
         {:ok, proved} <- attach_proof(injected, p) do
      {:ok, %{key => proved, "recipientInboxes" => p["recipientInboxes"]}}
    end
  end

  # A poll vote rides as a Create(Note) ballot: a tiny Note whose `name` is the
  # chosen option and whose `inReplyTo` is the remote Question, addressed `to`
  # the poll's author. No content, no cc — this is the Mastodon vote shape.
  defp vote(p) do
    object = %{
      "id" => p["noteId"],
      "type" => "Note",
      "attributedTo" => p["actor"],
      "name" => p["name"],
      "inReplyTo" => p["inReplyTo"],
      "to" => p["to"],
      "published" => now()
    }

    activity = %{
      "@context" => @context,
      "id" => p["activityId"],
      "type" => "Create",
      "actor" => p["actor"],
      "to" => p["to"],
      "object" => object
    }

    with {:ok, signed} <- sign_and_prove(p, activity) do
      {:ok, %{"note" => signed, "recipientInboxes" => p["recipientInboxes"]}}
    end
  end

  defp dm(p) do
    audience = Audience.direct(p["recipientActors"] || [])

    object =
      %{
        "id" => p["noteId"],
        "type" => "Note",
        "attributedTo" => p["actor"],
        "content" => p["content"],
        "published" => now(),
        "to" => audience.to,
        "cc" => audience.cc
      }
      |> put_if("inReplyTo", p["inReplyToId"])
      |> put_if("context", p["conversationId"])

    activity = wrap_create(p, object, audience)

    with {:ok, signed} <- sign(p, activity),
         injected =
           signed
           |> inject_misskey_content(p["content"])
           |> inject_attachments(p["attachments"]),
         {:ok, proved} <- attach_proof(injected, p) do
      {:ok, %{"note" => proved, "recipientInboxes" => p["recipientInboxes"]}}
    end
  end

  defp follow(p) do
    activity = %{
      "@context" => @context,
      "id" => p["activityId"],
      "type" => "Follow",
      "actor" => p["actor"],
      "object" => p["object"]
    }

    with {:ok, signed} <- sign_and_prove(p, activity) do
      {:ok, %{"follow" => signed}}
    end
  end

  # FEP-044f: ask a remote author for permission to quote their post.
  # `object` is the quoted post; `instrument` is our quote post — sent as
  # its URI (dereferenceable via NoteController), which the spec allows in
  # place of inlining it.
  defp quote_request(p) do
    activity = %{
      "@context" => @context,
      "id" => p["activityId"],
      "type" => "QuoteRequest",
      "actor" => p["actor"],
      "object" => p["object"],
      "instrument" => p["instrument"]
    }

    with {:ok, signed} <- sign_and_prove(p, activity) do
      {:ok, %{"quoteRequest" => signed}}
    end
  end

  defp announce(p) do
    audience = Audience.public(p["actor"])

    activity = %{
      "@context" => @context,
      "id" => p["activityId"],
      "type" => "Announce",
      "actor" => p["actor"],
      "object" => p["object"],
      "published" => now(),
      "to" => audience.to,
      "cc" => audience.cc
    }

    with {:ok, signed} <- sign_and_prove(p, activity) do
      {:ok, %{"announce" => signed, "recipientInboxes" => p["recipientInboxes"]}}
    end
  end

  defp like(p) do
    activity = %{
      "@context" => @context,
      "id" => p["activityId"],
      "type" => "Like",
      "actor" => p["actor"],
      "object" => p["object"],
      "published" => now()
    }

    with {:ok, signed} <- sign_and_prove(p, activity) do
      {:ok, %{"like" => signed, "recipientInboxes" => p["recipientInboxes"]}}
    end
  end

  # A Misskey-style emoji reaction rides as Like-with-content (recent
  # Misskey/Sharkey emit this; Mastodon reads it as a plain Like, while
  # Pleroma's EmojiReact gets quarantined there). Custom emoji attach a
  # matching `Emoji` tag with the icon URL.
  defp emoji_react(p) do
    activity =
      %{
        "@context" => @context,
        "id" => p["activityId"],
        "type" => "Like",
        "actor" => p["actor"],
        "object" => p["object"],
        "content" => p["content"],
        "published" => now()
      }
      |> put_if("tag", emoji_tag(p["tag"]))

    with {:ok, signed} <- sign_and_prove(p, activity) do
      {:ok, %{"emojiReact" => signed, "recipientInboxes" => p["recipientInboxes"]}}
    end
  end

  defp undo(p) do
    inner = p["inner"]

    audience = Audience.mirror(inner["object"])

    activity = %{
      "@context" => @context,
      "id" => p["activityId"],
      "type" => "Undo",
      "actor" => p["actor"],
      "object" => %{
        "id" => inner["id"],
        "type" => inner["type"],
        "actor" => p["actor"],
        "object" => inner["object"]
      },
      "published" => now(),
      "to" => audience.to,
      "cc" => audience.cc
    }

    with {:ok, signed} <- sign_and_prove(p, activity) do
      {:ok, %{"undo" => signed, "recipientInboxes" => p["recipientInboxes"]}}
    end
  end

  defp delete(p) do
    audience = Audience.public(p["actor"])

    activity = %{
      "@context" => @context,
      "id" => p["activityId"],
      "type" => "Delete",
      "actor" => p["actor"],
      "object" => %{"id" => p["objectId"], "type" => "Tombstone"},
      "published" => now(),
      "to" => audience.to,
      "cc" => audience.cc
    }

    with {:ok, signed} <- sign_and_prove(p, activity) do
      {:ok, %{"delete" => signed, "recipientInboxes" => p["recipientInboxes"]}}
    end
  end

  # Account migration (Mastodon Move). `actor` and `object` are the old
  # identity; `target` is the new one. Addressed to followers so their
  # servers re-point the follow to `target` (the same activity our inbound
  # handler consumes). Consent lives on the actor JSON, not here: the new
  # actor must list the old one in `alsoKnownAs`.
  defp move(p) do
    audience = Audience.followers_only(p["actor"])

    activity = %{
      "@context" => @context,
      "id" => p["activityId"],
      "type" => "Move",
      "actor" => p["actor"],
      "object" => p["actor"],
      "target" => p["target"],
      "published" => now(),
      "to" => audience.to,
      "cc" => audience.cc
    }

    with {:ok, signed} <- sign_and_prove(p, activity) do
      {:ok, %{"move" => signed, "recipientInboxes" => p["recipientInboxes"]}}
    end
  end

  defp collection_op(type, p) do
    activity = %{
      "@context" => @context,
      "id" => p["activityId"],
      "type" => type,
      "actor" => p["actor"],
      "object" => p["objectUri"],
      "target" => p["targetUri"]
    }

    with {:ok, signed} <- sign_and_prove(p, activity) do
      {:ok, %{"activity" => signed, "recipientInboxes" => p["recipientInboxes"]}}
    end
  end

  # ── Shared pieces ────────────────────────────────────────────────────────

  defp wrap_create(p, object, audience) do
    %{
      "@context" => @context,
      "id" => p["activityId"],
      "type" => "Create",
      "actor" => p["actor"],
      "to" => audience.to,
      "cc" => audience.cc,
      "object" => object
    }
  end

  defp sign(%{"privateKeyJwk" => jwk, "keyId" => key_id}, activity) do
    with {:ok, private_key} <- JWK.private_key(jwk) do
      LdSignature.sign(activity, private_key, key_id)
    end
  end

  defp sign(_p, _activity), do: {:error, :missing_signing_key}

  # FEP-8b32 proof, attached when the payload carries the actor's
  # Ed25519 key (absent on rows the migration backfill hasn't reached,
  # or when the delivery node predates it — the RSA signatures still
  # carry the activity then). A key that is present but unreadable is
  # a real error, not a silent downgrade.
  defp attach_proof(activity, %{"ed25519PrivateKeyJwk" => jwk, "ed25519KeyId" => key_id}) do
    with {:ok, private_key} <- JWK.ed25519_private_key(jwk) do
      Oip.sign(activity, private_key, key_id)
    end
  end

  defp attach_proof(activity, _p), do: {:ok, activity}

  # fedify's order, for builders without post-sign injections: proof
  # first, LD signature over it, so both survive verification (see
  # moduledoc).
  defp sign_and_prove(p, activity) do
    with {:ok, proved} <- attach_proof(activity, p) do
      sign(p, proved)
    end
  end

  # ── Post-signature compatibility injections (parity with utils.ts) ──────

  defp inject_misskey_content(activity, content),
    do: update_object(activity, &Map.put(&1, "_misskey_content", content))

  # The Misskey-style aliases + the FEP-e232 tag Link, injected post-sign
  # (parity with the historical Bun path). The FEP-044f canonical `quote`
  # and the `interactionPolicy` ride *inside* the signed object (see
  # `note/1`); these aliases widen reach to Misskey-family and older
  # forks that don't read `quote`.
  defp inject_quote(activity, quote_uri) when is_binary(quote_uri) and quote_uri != "" do
    update_object(activity, fn object ->
      tags = List.wrap(object["tag"] || [])

      quote_link = %{
        "type" => "Link",
        "mediaType" => ~s(application/ld+json; profile="https://www.w3.org/ns/activitystreams"),
        "href" => quote_uri,
        "name" => "RE: #{quote_uri}",
        "rel" => "https://misskey-hub.net/ns#_misskey_quote"
      }

      object
      |> Map.put("quoteUrl", quote_uri)
      |> Map.put("_misskey_quote", quote_uri)
      |> Map.put("tag", tags ++ [quote_link])
    end)
  end

  defp inject_quote(activity, _), do: activity

  defp inject_attachments(activity, [_ | _] = attachments) do
    documents =
      Enum.map(attachments, fn a ->
        %{"type" => "Document", "url" => a["url"]}
        |> put_if("mediaType", a["mediaType"])
        |> put_if("name", a["name"])
        |> put_if("blurhash", a["blurhash"])
        |> put_if("width", a["width"])
        |> put_if("height", a["height"])
      end)

    update_object(activity, &Map.put(&1, "attachment", documents))
  end

  defp inject_attachments(activity, _), do: activity

  defp update_object(%{"object" => object} = activity, fun) when is_map(object),
    do: %{activity | "object" => fun.(object)}

  defp update_object(activity, _fun), do: activity

  defp emoji_tag(%{"name" => name, "url" => url}) do
    [
      %{
        "type" => "Emoji",
        "name" => name,
        "icon" => %{"type" => "Image", "url" => url}
      }
    ]
  end

  defp emoji_tag(_), do: nil

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
