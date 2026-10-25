# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.Handlers.Social do
  @moduledoc """
  `sns.outbox.*` events about relationships and reactions: follow, like,
  emoji reaction, announce (boost), featured add/remove, account Move and actor
  Update. Each function takes the event payload and returns what
  `Outbox.Consumer` hands to the dispatch worker.
  """

  alias SukhiDelivery.Repo
  alias SukhiDelivery.Schema.Account

  import SukhiDelivery.Outbox.Payload, only: [maybe_attach_emoji_tag: 2]

  import SukhiDelivery.Outbox.Recipients,
    only: [
      actor_for: 1,
      followee_endpoints: 1,
      follower_uri_to_account: 1,
      followed_inboxes: 1,
      followers_inboxes: 1,
      local_actor_uri: 1,
      note_author_inbox: 1,
      parse_id: 1,
      relay_inboxes: 0
    ]

  import SukhiDelivery.Outbox.Fanout,
    only: [enqueue_jobs: 4, translate_and_fanout: 5, translate_and_fanout: 6]

  def follow(%{"follower_uri" => follower_uri, "followee_id" => followee_id} = p, mode) do
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

  def follow(_, _), do: :missing_fields

  def like(%{"account_id" => account_id, "note_ap_id" => note_ap_id} = p, mode) do
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

  def like(_, _), do: :missing_fields

  def reaction(%{"account_id" => account_id, "note_ap_id" => note_ap_id} = p, mode) do
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

  def reaction(_, _), do: :missing_fields

  # 板が新しく立った話を配る。人の boost と同じ `announce` translator を
  # 通すが、actor も配り先も板のもの ── 板は accounts に居ないので、
  # 下の `account_id` 前提の節には落ちない。
  #
  # 形は `Announce(<note の URI>)`。FEP-1b12 は `Announce(Create(…))` を
  # 本筋と書いているが、Mastodon の Announce は object がオブジェクトで
  # ある前提なので、中身がアクティビティだと弾かれる。掲示板を持つ実装
  # は URI を引きに来て、そこで `audience` を見つけられる。
  def announce(
        %{"deco_actor" => actor_uri, "object" => object, "inboxes" => inboxes} = p,
        :create
      )
      when is_binary(actor_uri) and is_binary(object) and is_list(inboxes) do
    recipients = Enum.uniq(inboxes)
    activity_id = p["activity_id"] || "#{actor_uri}/announces/#{:erlang.phash2(object)}"

    payload = %{
      actor: actor_uri,
      object: object,
      activityId: activity_id,
      recipientInboxes: recipients
    }

    translate_and_fanout("announce", payload, actor_uri, activity_id, recipients)
  end

  def announce(%{"account_id" => account_id, "note_ap_id" => note_ap_id} = p, mode) do
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

  def announce(_, _), do: :missing_fields

  def collection_op(%{"account_id" => account_id, "note_ap_id" => note_ap_id} = p, op) do
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

  def collection_op(_, _), do: :missing_fields

  # Account migration. Fan a Move out to the migrating account's followers
  # so their servers re-point the follow to `target` (the new identity).
  def move(%{"account_id" => account_id, "target" => target} = p)
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

  def move(_), do: :missing_fields

  def actor_updated(%{"account_id" => account_id}) do
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

  def actor_updated(_), do: :missing_fields

  # The owner closed the account (SukhiFedi.AccountDeletion). One `Delete`
  # whose object is the actor itself — the shape Mastodon and Misskey take
  # as "forget this person". It is enqueued after the notes are gone and
  # the follow rows are kept, so both the followers and the accounts this
  # one followed (which hold its Follow) are still here to read.
  def actor_deleted(%{"account_id" => account_id}) do
    case actor_for(account_id) do
      nil ->
        :no_actor

      %{actor_uri: actor_uri} ->
        recipients =
          Enum.uniq(
            followers_inboxes(actor_uri) ++ followed_inboxes(actor_uri) ++ relay_inboxes()
          )

        activity_id = "#{actor_uri}#delete"

        payload = %{
          actor: actor_uri,
          activityId: activity_id,
          objectId: actor_uri,
          recipientInboxes: recipients
        }

        translate_and_fanout("delete", payload, actor_uri, activity_id, recipients,
          extract: "delete"
        )
    end
  end

  def actor_deleted(_), do: :missing_fields
end
