# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.Consumer do
  @moduledoc """
  Subscribes to `sns.outbox.>` and turns each event into one or more
  Oban delivery jobs.

  ## Subject coverage

      sns.outbox.note.created       → Bun `note` translator   → fan out
      sns.outbox.note.deleted       → Bun `delete` translator → fan out
      sns.outbox.dm.created         → Bun `dm` translator     → direct recipient inboxes
      sns.outbox.follow.requested   → Bun `follow` translator → followee inbox
      sns.outbox.quote.requested    → `quote_request` (FEP-044f)→ quoted author inbox
      sns.outbox.follow.undone      → Bun `undo` (Follow)     → followee inbox
      sns.outbox.like.created       → Bun `like` translator   → note author + relays
      sns.outbox.like.undone        → Bun `undo` (Like)       → note author
      sns.outbox.reaction.created   → Bun `emoji_react`       → note author + relays
      sns.outbox.reaction.undone    → Bun `undo` (EmojiReact) → note author
      sns.outbox.announce.created   → Bun `announce`          → note author + followers
      sns.outbox.announce.undone    → Bun `undo` (Announce)   → note author + followers
      sns.outbox.add.created        → Bun `add` (featured)    → followers
      sns.outbox.remove.created     → Bun `remove` (featured) → followers
      sns.outbox.follow.backfill    → Bun `note` translator   → single new-follower inbox
      sns.outbox.move.created       → `move` translator       → followers (account migration)

      sns.outbox.actor.updated      → AP.ActorJson Update(Person)  → followers + relays

  Ignored:
    * `sns.outbox.oauth.app_registered` — local-only, no federation

  ## Stream cleanup

  This module is the *dispatch* surface. Subscription + ACK happens in
  `SukhiDelivery.Outbox.PullConsumer`, which uses a durable JetStream
  consumer with explicit ACK — the OUTBOX stream is a WorkQueue, so
  each message is deleted as soon as it's ACKed.

  Return values inform the PullConsumer's ack policy: anything that
  could succeed on retry returns `:translate_failed` or `:crashed`
  (→ NACK); structural problems (`:missing_*`, `:no_*`, `:bad_json`,
  `:ignored`, `:no_handler`) return immediately (→ ACK; retry can't
  help).

  ## Recipient inbox resolution

  Local actor (`actor_uri` host == ours) → `<actor_uri>/inbox`
  (no network hop). Remote actor → `Federation.ActorFetcher.inbox_for/1`,
  which prefers `endpoints.sharedInbox` then `inbox` from the
  remote's actor JSON and falls back to the convention.
  """

  require Logger

  import Ecto.Query

  alias SukhiDelivery.{Repo, Relays}
  alias SukhiDelivery.Delivery.{FedifyClient, Worker}
  alias SukhiDelivery.Schema.{Account, Follow}

  # ── event dispatch ───────────────────────────────────────────────────────

  @doc false
  def handle_event(subject, body) when is_binary(subject) and is_binary(body) do
    case JSON.decode(body) do
      {:ok, payload} when is_map(payload) ->
        try do
          dispatch(subject, payload)
        rescue
          e ->
            Logger.error(
              "Outbox.Consumer dispatch crash subject=#{subject}: " <>
                Exception.format(:error, e, __STACKTRACE__)
            )

            :crashed
        end

      _ ->
        Logger.warning("Outbox.Consumer: malformed JSON for #{subject}")
        :bad_json
    end
  end

  @doc false
  def dispatch("sns.outbox.note.created", p), do: handle_note_created(p)
  def dispatch("sns.outbox.note.updated", p), do: handle_note_updated(p)
  def dispatch("sns.outbox.note.deleted", p), do: handle_note_deleted(p)
  def dispatch("sns.outbox.vote.created", p), do: handle_vote(p)
  def dispatch("sns.outbox.dm.created", p), do: handle_dm(p)
  def dispatch("sns.outbox.quote.requested", p), do: handle_quote_requested(p)
  def dispatch("sns.outbox.follow.requested", p), do: handle_follow(p, :create)
  def dispatch("sns.outbox.follow.undone", p), do: handle_follow(p, :undo)
  def dispatch("sns.outbox.like.created", p), do: handle_like(p, :create)
  def dispatch("sns.outbox.like.undone", p), do: handle_like(p, :undo)
  def dispatch("sns.outbox.reaction.created", p), do: handle_reaction(p, :create)
  def dispatch("sns.outbox.reaction.undone", p), do: handle_reaction(p, :undo)
  def dispatch("sns.outbox.announce.created", p), do: handle_announce(p, :create)
  def dispatch("sns.outbox.announce.undone", p), do: handle_announce(p, :undo)
  def dispatch("sns.outbox.add.created", p), do: handle_collection_op(p, :add)
  def dispatch("sns.outbox.remove.created", p), do: handle_collection_op(p, :remove)
  def dispatch("sns.outbox.follow.backfill", p), do: handle_follow_backfill(p)
  def dispatch("sns.outbox.move.created", p), do: handle_move(p)

  def dispatch("sns.outbox.actor.updated", p), do: handle_actor_updated(p)

  def dispatch("sns.outbox.oauth.app_registered", _p) do
    # local audit only — no federation
    :ignored
  end

  def dispatch(subject, _p) do
    Logger.debug("Outbox.Consumer: no handler for subject #{subject}")
    :no_handler
  end

  # ── handlers ─────────────────────────────────────────────────────────────

  defp handle_note_created(%{"local_only" => true}), do: :local_only

  defp handle_note_created(%{"account_id" => account_id} = p) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        # 返信は親の書いた人に、本文の @メンションはその人自身に届くように
        # ── これまではフォロワー+リレーだけで、フォローし合っていない
        # 相手には(返信もメンションも)何も届いていなかった。
        reply_inbox = note_author_inbox(p["in_reply_to_ap_id"])

        mention_inboxes =
          (p["mention_actor_uris"] || [])
          |> Enum.map(&inbox_for_actor_uri/1)
          |> Enum.reject(&is_nil/1)

        recipients =
          (followers_inboxes(actor_uri) ++ relay_inboxes() ++ reply_inbox ++ mention_inboxes)
          |> Enum.uniq()

        note_id = p["note_id"]
        ap_id = note_ap_id(actor_uri, note_id)
        activity_id = "#{ap_id}/activity"

        translator_payload =
          %{
            actor: actor_uri,
            content: p["content"] || "",
            recipientInboxes: recipients,
            noteId: ap_id,
            activityId: activity_id,
            inReplyToId: p["in_reply_to_ap_id"]
          }
          |> maybe_put_quote(p["quote_of_ap_id"])
          |> maybe_put_attachments(p["media"])
          |> maybe_put_cw(p["cw"])
          |> maybe_put_sensitive(p["sensitive"])
          |> maybe_put_emojis(p["emojis"])
          # 題つきの投稿は、線の上で本文の頭に「> 題 — @書いた人」を
          # 添える。組むのは builders 側 ── ここは運ぶだけ。
          |> maybe_put_titled(p)

        translate_and_fanout("note", translator_payload, actor_uri, activity_id, recipients,
          extract_note: true
        )
    end
  end

  defp handle_note_created(_), do: :missing_account

  # FEP-044f re-delivery: a quote authorization landed (or was withdrawn),
  # so push an `Update(Note)` to followers + relays. The activity id is
  # deterministic per state — distinct between an accept (stamp present)
  # and a reject (quote removed) so neither suppresses the other on the
  # receiver, while a retry of the same state stays idempotent.
  defp handle_note_updated(%{"account_id" => account_id} = p) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipients = followers_inboxes(actor_uri) ++ relay_inboxes()
        ap_id = note_ap_id(actor_uri, p["note_id"])
        activity_id = "#{ap_id}#update-#{update_tag(p)}"

        translator_payload =
          %{
            actor: actor_uri,
            content: p["content"] || "",
            recipientInboxes: recipients,
            noteId: ap_id,
            activityId: activity_id,
            published: p["published"],
            inReplyToId: p["in_reply_to_ap_id"]
          }
          |> maybe_put_quote(p["quote_of_ap_id"])
          |> maybe_put_quote_authorization(p["quote_authorization_ap_id"])
          |> maybe_put_attachments(p["media"])
          |> maybe_put_cw(p["cw"])
          |> maybe_put_sensitive(p["sensitive"])

        translate_and_fanout("update", translator_payload, actor_uri, activity_id, recipients,
          extract: "update"
        )
    end
  end

  defp handle_note_updated(_), do: :missing_account

  defp update_tag(%{"quote_authorization_ap_id" => stamp}) when is_binary(stamp), do: "quote-auth"
  defp update_tag(%{"quote_of_ap_id" => q}) when is_binary(q), do: "quote"
  defp update_tag(_), do: "quote-removed"

  defp handle_note_deleted(%{"account_id" => account_id, "ap_id" => ap_id} = _p) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipients = followers_inboxes(actor_uri) ++ relay_inboxes()
        activity_id = "#{ap_id}#delete"

        translator_payload = %{
          actor: actor_uri,
          activityId: activity_id,
          objectId: ap_id,
          recipientInboxes: recipients
        }

        translate_and_fanout("delete", translator_payload, actor_uri, activity_id, recipients,
          extract: "delete"
        )
    end
  end

  defp handle_note_deleted(_), do: :missing_fields

  # A local user voted on a remote poll. Send one Create(Note) ballot to the
  # Question's author: a Note whose `name` is the chosen option and `inReplyTo`
  # the Question, addressed to the author. The activity id is deterministic per
  # (voter, poll, option) so re-sending the same choice is idempotent on the
  # receiver.
  defp handle_vote(
         %{"account_id" => account_id, "question_ap_id" => question_ap_id, "name" => name} = p
       )
       when is_binary(question_ap_id) and is_binary(name) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipients = note_author_inbox(question_ap_id)
        ballot_id = "#{actor_uri}/poll-votes/#{p["poll_id"]}-#{p["option_id"]}"
        activity_id = "#{ballot_id}/activity"

        payload = %{
          actor: actor_uri,
          noteId: ballot_id,
          name: name,
          inReplyTo: question_ap_id,
          to: note_author_uri(question_ap_id),
          activityId: activity_id,
          recipientInboxes: recipients
        }

        translate_and_fanout("vote", payload, actor_uri, activity_id, recipients)
    end
  end

  defp handle_vote(_), do: :missing_fields

  defp handle_dm(%{"account_id" => account_id, "note_id" => note_id} = p) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipient_uris = p["recipient_actor_uris"] || []

        inboxes =
          recipient_uris
          |> Enum.map(&inbox_for_actor_uri/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        ap_id = note_ap_id(actor_uri, note_id)
        activity_id = "#{ap_id}/activity"

        payload =
          %{
            actor: actor_uri,
            content: p["content"] || "",
            recipientActors: recipient_uris,
            noteId: ap_id,
            activityId: activity_id,
            recipientInboxes: inboxes,
            inReplyToId: p["in_reply_to_ap_id"],
            conversationId: p["conversation_ap_id"]
          }
          |> maybe_put_attachments(p["media"])

        translate_and_fanout("dm", payload, actor_uri, activity_id, inboxes)
    end
  end

  defp handle_dm(_), do: :missing_fields

  defp handle_follow(%{"follower_uri" => follower_uri, "followee_id" => followee_id} = p, mode) do
    case follower_uri_to_account(follower_uri) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        followee = Repo.get(Account, followee_id)

        if followee do
          {followee_uri, followee_inbox} = followee_endpoints(followee)
          domain = SukhiDelivery.Config.domain!()

          activity_id =
            "https://#{domain}/follows/#{p["follow_id"]}#{if mode == :undo, do: "/undo", else: ""}"

          case mode do
            :create ->
              payload = %{actor: actor_uri, object: followee_uri, activityId: activity_id}
              translate_and_fanout("follow", payload, actor_uri, activity_id, [followee_inbox])

            :undo ->
              payload = %{
                actor: actor_uri,
                activityId: activity_id,
                recipientInboxes: [followee_inbox],
                inner: %{
                  type: "Follow",
                  id: "https://#{domain}/follows/#{p["follow_id"]}",
                  object: followee_uri
                }
              }

              translate_and_fanout("undo", payload, actor_uri, activity_id, [followee_inbox])
          end
        else
          :no_followee
        end
    end
  end

  defp handle_follow(_, _), do: :missing_fields

  defp handle_like(%{"account_id" => account_id, "note_ap_id" => note_ap_id} = p, mode) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipients = note_author_inbox(note_ap_id) ++ relay_inboxes()
        domain = SukhiDelivery.Config.domain!()

        activity_id =
          "https://#{domain}/likes/#{p["reaction_id"]}#{if mode == :undo, do: "/undo", else: ""}"

        case mode do
          :create ->
            payload = %{
              actor: actor_uri,
              object: note_ap_id,
              activityId: activity_id,
              recipientInboxes: recipients
            }

            translate_and_fanout("like", payload, actor_uri, activity_id, recipients)

          :undo ->
            payload = %{
              actor: actor_uri,
              activityId: activity_id,
              recipientInboxes: recipients,
              inner: %{
                type: "Like",
                id: "https://#{domain}/likes/#{p["reaction_id"]}",
                object: note_ap_id
              }
            }

            translate_and_fanout("undo", payload, actor_uri, activity_id, recipients)
        end
    end
  end

  defp handle_like(_, _), do: :missing_fields

  defp handle_reaction(%{"account_id" => account_id, "note_ap_id" => note_ap_id} = p, mode) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipients = note_author_inbox(note_ap_id) ++ relay_inboxes()
        domain = SukhiDelivery.Config.domain!()

        # Reactions ride as Like on the wire (Mastodon accepts it as
        # a plain favourite, Misskey/Sharkey read the content + tag).
        # Activity id lives under /likes/ for consistency with that.
        activity_id =
          "https://#{domain}/likes/#{p["reaction_id"]}#{if mode == :undo, do: "/undo", else: ""}"

        case mode do
          :create ->
            payload =
              %{
                actor: actor_uri,
                object: note_ap_id,
                content: p["emoji"],
                activityId: activity_id,
                recipientInboxes: recipients
              }
              |> maybe_attach_emoji_tag(p["emoji"])

            translate_and_fanout("emoji_react", payload, actor_uri, activity_id, recipients)

          :undo ->
            payload = %{
              actor: actor_uri,
              activityId: activity_id,
              recipientInboxes: recipients,
              inner: %{
                type: "Like",
                id: "https://#{domain}/likes/#{p["reaction_id"]}",
                object: note_ap_id
              }
            }

            translate_and_fanout("undo", payload, actor_uri, activity_id, recipients)
        end
    end
  end

  defp handle_reaction(_, _), do: :missing_fields

  # Local custom emoji only — domain IS NULL row in `custom_emojis`.
  # Unicode reactions and remote shortcodes leave tag absent.
  defp maybe_attach_emoji_tag(payload, emoji) when is_binary(emoji) do
    with [_, shortcode] <- Regex.run(~r/^:([^:@]+)(?:@\.)?:$/, emoji),
         %SukhiDelivery.Schema.CustomEmoji{image_url: url, static_url: static_url} <-
           Repo.get_by(SukhiDelivery.Schema.CustomEmoji, shortcode: shortcode, domain: nil) do
      Map.put(payload, :tag, %{name: ":#{shortcode}:", url: url, static_url: static_url})
    else
      _ -> payload
    end
  end

  defp maybe_attach_emoji_tag(payload, _), do: payload

  defp handle_announce(%{"account_id" => account_id, "note_ap_id" => note_ap_id} = p, mode) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipients =
          followers_inboxes(actor_uri) ++ note_author_inbox(note_ap_id) ++ relay_inboxes()

        recipients = Enum.uniq(recipients)
        domain = SukhiDelivery.Config.domain!()

        activity_id =
          "https://#{domain}/announces/#{p["boost_id"]}#{if mode == :undo, do: "/undo", else: ""}"

        case mode do
          :create ->
            payload = %{
              actor: actor_uri,
              object: note_ap_id,
              activityId: activity_id,
              recipientInboxes: recipients
            }

            translate_and_fanout("announce", payload, actor_uri, activity_id, recipients)

          :undo ->
            payload = %{
              actor: actor_uri,
              activityId: activity_id,
              recipientInboxes: recipients,
              inner: %{
                type: "Announce",
                id: "https://#{domain}/announces/#{p["boost_id"]}",
                object: note_ap_id
              }
            }

            translate_and_fanout("undo", payload, actor_uri, activity_id, recipients)
        end
    end
  end

  defp handle_announce(_, _), do: :missing_fields

  defp handle_collection_op(%{"account_id" => account_id, "note_ap_id" => note_ap_id} = p, op) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipients = followers_inboxes(actor_uri) ++ relay_inboxes()
        domain = SukhiDelivery.Config.domain!()
        activity_id = "https://#{domain}/#{op}/#{p["pinned_id"]}"
        target_uri = "#{actor_uri}/featured"

        payload = %{
          actor: actor_uri,
          objectUri: note_ap_id,
          targetUri: target_uri,
          activityId: activity_id,
          recipientInboxes: recipients
        }

        translate_and_fanout(Atom.to_string(op), payload, actor_uri, activity_id, recipients)
    end
  end

  defp handle_collection_op(_, _), do: :missing_fields

  defp handle_follow_backfill(
         %{
           "account_id" => account_id,
           "note_id" => note_id,
           "follower_inbox" => follower_inbox
         } = p
       )
       when is_binary(follower_inbox) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipients = [follower_inbox]
        ap_id = note_ap_id(actor_uri, note_id)
        activity_id = "#{ap_id}/activity"

        translator_payload =
          %{
            actor: actor_uri,
            content: p["content"] || "",
            recipientInboxes: recipients,
            noteId: ap_id,
            activityId: activity_id,
            inReplyToId: p["in_reply_to_ap_id"]
          }
          |> maybe_put_quote(p["quote_of_ap_id"])
          |> maybe_put_attachments(p["media"])
          |> maybe_put_cw(p["cw"])
          |> maybe_put_sensitive(p["sensitive"])

        translate_and_fanout("note", translator_payload, actor_uri, activity_id, recipients,
          extract_note: true
        )
    end
  end

  defp handle_follow_backfill(_), do: :missing_fields

  # FEP-044f: deliver our `QuoteRequest` to the quoted post's author (the
  # gateway resolved their inbox into `target_inbox`). `instrument` is our
  # quote post's URI — dereferenceable, so it need not be inlined.
  defp handle_quote_requested(
         %{
           "account_id" => account_id,
           "note_id" => note_id,
           "quote_of_ap_id" => quoted_uri,
           "target_inbox" => inbox
         }
       )
       when is_binary(quoted_uri) and is_binary(inbox) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        our_note_uri = note_ap_id(actor_uri, note_id)
        activity_id = "#{our_note_uri}/quote-request"

        payload = %{
          actor: actor_uri,
          object: quoted_uri,
          instrument: our_note_uri,
          activityId: activity_id,
          recipientInboxes: [inbox]
        }

        translate_and_fanout("quote_request", payload, actor_uri, activity_id, [inbox])
    end
  end

  defp handle_quote_requested(_), do: :missing_fields

  # Account migration. Fan a Move out to the migrating account's followers
  # so their servers re-point the follow to `target` (the new identity).
  defp handle_move(%{"account_id" => account_id, "target" => target} = p)
       when is_binary(target) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipients = followers_inboxes(actor_uri)
        domain = SukhiDelivery.Config.domain!()
        activity_id = "https://#{domain}/moves/#{p["move_id"]}"

        payload = %{
          actor: actor_uri,
          target: target,
          activityId: activity_id,
          recipientInboxes: recipients
        }

        translate_and_fanout("move", payload, actor_uri, activity_id, recipients)
    end
  end

  defp handle_move(_), do: :missing_fields

  defp handle_actor_updated(%{"account_id" => account_id}) do
    case Repo.get(Account, parse_id(account_id)) do
      nil ->
        :no_actor

      %Account{} = account ->
        actor_uri = local_actor_uri(account)
        recipients = followers_inboxes(actor_uri) ++ relay_inboxes()

        update_json = SukhiDelivery.AP.ActorJson.build_update(account)
        activity_id = update_json["id"]

        enqueue_jobs(update_json, actor_uri, activity_id, recipients)
    end
  end

  defp handle_actor_updated(_), do: :missing_fields

  defp local_actor_uri(%Account{username: u}) do
    domain = SukhiDelivery.Config.domain!()
    "https://#{domain}/users/#{u}"
  end

  defp parse_id(id) when is_integer(id), do: id
  defp parse_id(id) when is_binary(id), do: String.to_integer(id)

  # ── translation + fan-out ────────────────────────────────────────────────

  defp translate_and_fanout(object_type, payload, actor_uri, activity_id, inboxes, opts \\ []) do
    payload = inject_signing_for(payload, actor_uri)

    case FedifyClient.translate(object_type, payload) do
      {:ok, translator_result} ->
        body =
          extract_body(translator_result, object_type, opts)

        enqueue_jobs(body, actor_uri, activity_id, inboxes)

      {:error, reason} ->
        Logger.warning("Outbox.Consumer: translate(#{object_type}) failed: #{inspect(reason)}")

        :translate_failed
    end
  end

  # Bun translator results carry the payload under different keys per
  # type. Pick the right one — fall back to the whole result.
  defp extract_body(result, "note", _opts), do: Map.get(result, "note", result)
  defp extract_body(result, "update", _opts), do: Map.get(result, "update", result)
  defp extract_body(result, "vote", _opts), do: Map.get(result, "note", result)
  defp extract_body(result, "dm", _opts), do: Map.get(result, "note", result)
  defp extract_body(result, "delete", _opts), do: Map.get(result, "delete", result)
  defp extract_body(result, "follow", _opts), do: Map.get(result, "follow", result)
  defp extract_body(result, "quote_request", _opts), do: Map.get(result, "quoteRequest", result)
  defp extract_body(result, "announce", _opts), do: Map.get(result, "announce", result)
  defp extract_body(result, "like", _opts), do: Map.get(result, "like", result)
  defp extract_body(result, "emoji_react", _opts), do: Map.get(result, "emojiReact", result)
  defp extract_body(result, "undo", _opts), do: Map.get(result, "undo", result)
  defp extract_body(result, "move", _opts), do: Map.get(result, "move", result)
  defp extract_body(result, "add", _opts), do: Map.get(result, "activity", result)
  defp extract_body(result, "remove", _opts), do: Map.get(result, "activity", result)
  defp extract_body(result, _type, _opts), do: result

  defp enqueue_jobs(_body, _actor_uri, _activity_id, []), do: :no_recipients

  defp enqueue_jobs(body, actor_uri, activity_id, inboxes) do
    inboxes = Enum.uniq(inboxes)

    base = %{
      raw_json: body,
      actor_uri: actor_uri,
      activity_id: activity_id
    }

    changesets =
      Enum.map(inboxes, fn inbox -> base |> Map.put(:inbox_url, inbox) |> Worker.new() end)

    Oban.insert_all(SukhiDelivery.Oban, changesets)
    :ok
  end

  # ── DB helpers ───────────────────────────────────────────────────────────

  # A genuinely-missing account (Repo.get → nil) or an unparseable id is
  # structural → nil → :no_actor → ACK. But a transient DB error (Repo.get
  # raising on a dropped connection) must NOT be swallowed to nil: that maps a
  # retryable failure onto the permanent :no_actor path and silently drops the
  # outbound activity for an account that really exists. So we no longer
  # blanket-rescue — a DB exception bubbles to handle_event/2's try, which
  # returns :crashed (transient → backoff + retry, never an instant ACK).
  defp actor_for(account_id) when is_integer(account_id) or is_binary(account_id) do
    case safe_account_id(account_id) do
      nil ->
        nil

      id ->
        case Repo.get(Account, id) do
          nil ->
            nil

          %Account{username: u} ->
            domain = SukhiDelivery.Config.domain!()
            %{actor_uri: "https://#{domain}/users/#{u}", username: u}
        end
    end
  end

  defp safe_account_id(id) when is_integer(id), do: id

  defp safe_account_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # Add the RSA private JWK + keyId every translator needs so the bun
  # builder can produce a valid RsaSignature2017 LD-sig. Without these
  # bun would fall back to generating an in-memory Ed25519 keypair
  # whose signature can't be verified against the actor's published
  # publicKeyPem — that mismatch is what hackers.pub was choking on.
  defp inject_signing_for(payload, actor_uri)
       when is_map(payload) and is_binary(actor_uri) do
    domain = SukhiDelivery.Config.domain!()
    expected_prefix = "https://#{domain}/users/"

    if String.starts_with?(actor_uri, expected_prefix) do
      username = String.replace_prefix(actor_uri, expected_prefix, "")

      case SukhiDelivery.Accounts.by_local_username(username) do
        %Account{private_key_jwk: jwk} = account when is_map(jwk) ->
          payload
          |> Map.put(:privateKeyJwk, jwk)
          |> Map.put(:keyId, "#{actor_uri}#main-key")
          |> put_ed25519_signing(account, actor_uri)

        _ ->
          payload
      end
    else
      payload
    end
  end

  defp inject_signing_for(payload, _), do: payload

  # The Ed25519 key signs a FEP-8b32 Object Integrity Proof alongside
  # the RSA LD-sig. The keyId must match the `assertionMethod` Multikey
  # id ActorJson publishes, or receivers can't resolve the proof.
  defp put_ed25519_signing(payload, %Account{ed25519_private_key_jwk: jwk}, actor_uri)
       when is_map(jwk) do
    payload
    |> Map.put(:ed25519PrivateKeyJwk, jwk)
    |> Map.put(:ed25519KeyId, "#{actor_uri}#ed25519-key")
  end

  defp put_ed25519_signing(payload, _account, _actor_uri), do: payload

  defp follower_uri_to_account(follower_uri) when is_binary(follower_uri) do
    domain = SukhiDelivery.Config.domain!()
    expected_prefix = "https://#{domain}/users/"

    if String.starts_with?(follower_uri, expected_prefix) do
      username = String.replace_prefix(follower_uri, expected_prefix, "")

      case SukhiDelivery.Accounts.by_local_username(username) do
        nil -> nil
        _ -> %{actor_uri: follower_uri, username: username}
      end
    else
      # Remote actor following us — they'd never be the source of an outbound activity.
      nil
    end
  end

  defp followers_inboxes(actor_uri) do
    domain = SukhiDelivery.Config.domain!()
    expected_prefix = "https://#{domain}/users/"

    if String.starts_with?(actor_uri, expected_prefix) do
      username = String.replace_prefix(actor_uri, expected_prefix, "")

      case SukhiDelivery.Accounts.by_local_username(username) do
        nil ->
          []

        %Account{id: id} ->
          from(f in Follow,
            where: f.followee_id == ^id and f.state == "accepted",
            select: f.follower_uri
          )
          |> Repo.all()
          |> Enum.map(&inbox_for_actor_uri/1)
          |> Enum.reject(&is_nil/1)
      end
    else
      []
    end
  end

  defp note_author_inbox(note_ap_id) when is_binary(note_ap_id) do
    # Convention: a note URI is `<actor_uri>/notes/<id>` or similar; the
    # author's actor URI is the parent path. This works for our own
    # notes and for Mastodon-shaped URIs. Best-effort.
    case URI.parse(note_ap_id) do
      %URI{scheme: scheme, host: host, path: path}
      when is_binary(scheme) and is_binary(host) and is_binary(path) ->
        # Strip the trailing `/notes/<id>` or `/statuses/<id>`
        actor_path =
          path
          |> String.split("/")
          |> Enum.reverse()
          |> Enum.drop(2)
          |> Enum.reverse()
          |> Enum.join("/")

        if actor_path == "" do
          []
        else
          ["#{scheme}://#{host}#{actor_path}/inbox"]
        end

      _ ->
        []
    end
  end

  defp note_author_inbox(_), do: []

  # The author's actor URI for a note URI (`<actor_uri>/notes/<id>`), used to
  # address a poll-vote ballot `to` the Question's author. Same convention as
  # note_author_inbox/1, minus the `/inbox` suffix. Returns [] when unparseable
  # so the ballot is still built (best-effort addressing).
  defp note_author_uri(note_ap_id) when is_binary(note_ap_id) do
    case URI.parse(note_ap_id) do
      %URI{scheme: scheme, host: host, path: path}
      when is_binary(scheme) and is_binary(host) and is_binary(path) ->
        actor_path =
          path
          |> String.split("/")
          |> Enum.reverse()
          |> Enum.drop(2)
          |> Enum.reverse()
          |> Enum.join("/")

        if actor_path == "", do: [], else: ["#{scheme}://#{host}#{actor_path}"]

      _ ->
        []
    end
  end

  defp inbox_for_actor_uri(actor_uri) when is_binary(actor_uri) do
    if local_actor?(actor_uri) do
      # Local actor: skip the network hop, use convention.
      "#{actor_uri}/inbox"
    else
      # Remote actor: prefer sharedInbox / actor.inbox from the actor JSON.
      SukhiDelivery.Federation.ActorFetcher.inbox_for(actor_uri)
    end
  end

  defp inbox_for_actor_uri(_), do: nil

  # Exact host match, not a substring — `our.domain.evil.com` and
  # `evil.com/our.domain/...` must NOT count as local.
  defp local_actor?(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) ->
        String.downcase(host) == String.downcase(SukhiDelivery.Config.domain!())

      _ ->
        false
    end
  end

  # Local accounts (domain IS NULL) use the convention; remote shadow
  # accounts carry the actual `actor_uri` + `inbox_url` (or
  # `shared_inbox_url`) from the actor JSON.
  defp followee_endpoints(%Account{domain: nil, username: u}) do
    domain = SukhiDelivery.Config.domain!()
    uri = "https://#{domain}/users/#{u}"
    {uri, "#{uri}/inbox"}
  end

  defp followee_endpoints(%Account{actor_uri: uri} = a) when is_binary(uri) do
    inbox = a.shared_inbox_url || a.inbox_url || "#{uri}/inbox"
    {uri, inbox}
  end

  defp relay_inboxes, do: Relays.get_active_inbox_urls()

  defp note_ap_id(actor_uri, note_id) when is_binary(actor_uri) and not is_nil(note_id) do
    "#{actor_uri}/notes/#{note_id}"
  end

  defp note_ap_id(_, _), do: nil

  # A note may quote another (Misskey 引用ノート). Thread the quoted
  # AP id through to the `note` translator only when one is present.
  # 題が無ければ何も足さない ── 話す板の投稿は素の Note のまま。
  defp maybe_put_titled(payload, p) do
    case p["title"] do
      t when is_binary(t) and t != "" ->
        payload
        |> Map.put(:title, t)
        |> Map.put(:authorHandle, p["author_handle"])
        |> Map.put(:authorUri, p["author_uri"])

      _ ->
        payload
    end
  end

  defp maybe_put_quote(payload, quote_uri) when is_binary(quote_uri) and quote_uri != "" do
    Map.put(payload, :quoteUrl, quote_uri)
  end

  defp maybe_put_quote(payload, _), do: payload

  # FEP-044f: the authorization stamp we were granted for quoting a remote
  # post. Carried on the re-delivered Update so receivers verify the quote.
  defp maybe_put_quote_authorization(payload, stamp) when is_binary(stamp) and stamp != "" do
    Map.put(payload, :quoteAuthorization, stamp)
  end

  defp maybe_put_quote_authorization(payload, _), do: payload

  # The content warning rides as AP `summary`; only send it when present.
  defp maybe_put_cw(payload, cw) when is_binary(cw) and cw != "" do
    Map.put(payload, :summary, cw)
  end

  defp maybe_put_cw(payload, _), do: payload

  # `sensitive` defaults to absent (= not sensitive) on the wire, so only send
  # the flag when it's actually set.
  defp maybe_put_sensitive(payload, true), do: Map.put(payload, :sensitive, true)
  defp maybe_put_sensitive(payload, _), do: payload

  # Media descriptors built gateway-side by `SukhiFedi.AP.MediaSerialize`
  # ride through the outbox event under `media`. The bun `note` / `dm`
  # translator turns them into the Note's `attachment`.
  defp maybe_put_attachments(payload, media) when is_list(media) and media != [] do
    Map.put(payload, :attachments, media)
  end

  defp maybe_put_attachments(payload, _), do: payload

  defp maybe_put_emojis(payload, emojis) when is_list(emojis) and emojis != [] do
    Map.put(payload, :emojis, emojis)
  end

  defp maybe_put_emojis(payload, _), do: payload
end
