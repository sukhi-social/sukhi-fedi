# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.Handlers.Notes do
  @moduledoc """
  `sns.outbox.*` events about notes: create, edit, delete, poll votes, DMs,
  FEP-044f quote requests and the per-follower backfill. Each function takes the
  event payload and returns what `Outbox.Consumer` hands to the dispatch worker
  (`:ok`, or an atom saying why nothing was sent).
  """

  alias SukhiDelivery.PullFederation

  import SukhiDelivery.Outbox.Payload,
    only: [
      maybe_put_attachments: 2,
      maybe_put_audience: 2,
      maybe_put_cw: 2,
      maybe_put_emojis: 2,
      maybe_put_misskey_content: 2,
      maybe_put_quote: 2,
      maybe_put_quote_authorization: 2,
      maybe_put_sensitive: 2,
      maybe_put_titled: 2
    ]

  import SukhiDelivery.Outbox.Recipients,
    only: [
      actor_for: 1,
      followers_inboxes: 1,
      inbox_for_actor_uri: 1,
      note_ap_id: 2,
      note_author_inbox: 1,
      note_author_uri: 1,
      parse_id: 1,
      relay_inboxes: 0
    ]

  import SukhiDelivery.Outbox.Fanout, only: [translate_and_fanout: 5, translate_and_fanout: 6]

  def created(%{"local_only" => true}), do: :local_only

  def created(%{"account_id" => account_id} = p) do
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

        # Followers on a host that declared Pull Federation are told to pull
        # (`Route`); everyone else, and every reply/mention/relay target, is
        # pushed. A host that is pushed to anyway for this note (a mention
        # on the same shared inbox) is not also notified.
        {follower_push, pull_hosts} = PullFederation.Route.split(followers_inboxes(actor_uri))

        recipients =
          (follower_push ++ relay_inboxes() ++ reply_inbox ++ mention_inboxes)
          |> Enum.uniq()

        pull_hosts = pull_hosts -- Enum.map(recipients, &SukhiShared.PeerCapabilities.host_of/1)

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
          |> maybe_put_misskey_content(p["misskey_content"])
          |> maybe_put_quote(p["quote_of_ap_id"])
          |> maybe_put_attachments(p["media"])
          |> maybe_put_cw(p["cw"])
          |> maybe_put_sensitive(p["sensitive"])
          |> maybe_put_emojis(p["emojis"])
          # 題つきの投稿は、線の上で本文の頭に「> 題 — @書いた人」を
          # 添える。組むのは builders 側 ── ここは運ぶだけ。
          |> maybe_put_titled(p)
          # FEP-1b12: どの板のものか。表札のある板だけが持つ。
          |> maybe_put_audience(p["audience"])

        translate_and_fanout("note", translator_payload, actor_uri, activity_id, recipients,
          extract_note: true,
          pull: %{account_id: parse_id(account_id), hosts: pull_hosts}
        )
    end
  end

  def created(_), do: :missing_account

  # FEP-044f re-delivery: a quote authorization landed (or was withdrawn),
  # so push an `Update(Note)` to followers + relays. The activity id is
  # deterministic per state — distinct between an accept (stamp present)
  # and a reject (quote removed) so neither suppresses the other on the
  # receiver, while a retry of the same state stays idempotent.
  def updated(%{"account_id" => account_id} = p) do
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
          |> maybe_put_misskey_content(p["misskey_content"])
          |> maybe_put_quote(p["quote_of_ap_id"])
          |> maybe_put_quote_authorization(p["quote_authorization_ap_id"])
          |> maybe_put_attachments(p["media"])
          |> maybe_put_cw(p["cw"])
          |> maybe_put_sensitive(p["sensitive"])
          |> maybe_put_emojis(p["emojis"])

        translate_and_fanout("update", translator_payload, actor_uri, activity_id, recipients,
          extract: "update"
        )
    end
  end

  def updated(_), do: :missing_account

  defp update_tag(%{"quote_authorization_ap_id" => stamp}) when is_binary(stamp), do: "quote-auth"
  defp update_tag(%{"quote_of_ap_id" => q}) when is_binary(q), do: "quote"
  defp update_tag(_), do: "quote-removed"

  def deleted(%{"account_id" => account_id, "ap_id" => ap_id} = _p) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipients = followers_inboxes(actor_uri) ++ relay_inboxes()
        activity_id = "#{ap_id}#delete"

        # A Delete always goes by push, to everyone. Take the Create out of
        # the pull log so a puller is never handed the post it retracts.
        PullFederation.Log.retract("#{ap_id}/activity")

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

  def deleted(_), do: :missing_fields

  # A local user voted on a remote poll. Send one Create(Note) ballot to the
  # Question's author: a Note whose `name` is the chosen option and `inReplyTo`
  # the Question, addressed to the author. The activity id is deterministic per
  # (voter, poll, option) so re-sending the same choice is idempotent on the
  # receiver.
  def vote(%{"account_id" => account_id, "question_ap_id" => question_ap_id, "name" => name} = p)
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

  def vote(_), do: :missing_fields

  def dm(%{"account_id" => account_id, "note_id" => note_id} = p) do
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
          |> maybe_put_misskey_content(p["misskey_content"])
          |> maybe_put_attachments(p["media"])

        translate_and_fanout("dm", payload, actor_uri, activity_id, inboxes)
    end
  end

  def dm(_), do: :missing_fields

  def follow_backfill(
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

  def follow_backfill(_), do: :missing_fields

  # FEP-044f: deliver our `QuoteRequest` to the quoted post's author (the
  # gateway resolved their inbox into `target_inbox`). `instrument` is our
  # quote post's URI — dereferenceable, so it need not be inlined.
  def quote_requested(%{
        "account_id" => account_id,
        "note_id" => note_id,
        "quote_of_ap_id" => quoted_uri,
        "target_inbox" => inbox
      })
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

  def quote_requested(_), do: :missing_fields
end
