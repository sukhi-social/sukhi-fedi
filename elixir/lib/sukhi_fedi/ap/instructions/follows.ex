# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Instructions.Follows do
  @moduledoc """
  Inbound follow traffic: recording an auto-accepted `Follow` (with the
  Accept delivery, actor-cache nudge and recent-post backfill), flipping
  our outbound follows on `Accept(Follow)`, relay accepts, and
  `Undo(Follow)`.
  """

  import Ecto.Query

  alias SukhiFedi.AP.ActorJson
  alias SukhiFedi.AP.Instructions.{Extract, Resolve}
  alias SukhiFedi.{Notifications, Outbox, Relays, Repo}
  alias SukhiFedi.Schema.{Account, Follow, FollowRequest, Note}

  # How many recent public posts to replay to a brand-new follower so
  # their timeline isn't blank until our next outbound post.
  @backfill_limit 20

  # Delivery runs on a separate BEAM node with its own Oban supervisor
  # polling the :delivery queue. We reach its worker via the fully-
  # qualified worker string so the gateway has no compile-time dependency
  # on the delivery app.
  @delivery_worker "SukhiDelivery.Delivery.Worker"
  @delivery_queue "delivery"

  @doc """
  The `save_and_reply` body: persist the accepted follow, notify the
  followee, deliver the prepared Accept, and warm the new follower up
  (actor-cache nudge + recent-post backfill).
  """
  def handle_accepted_follow(save_data, reply, inbox_url) do
    followee = local_followee(save_data)

    if locked_and_uninvited?(save_data, followee) do
      # Locked account → the Follow waits in the request queue for the
      # owner. We deliberately do NOT send the prepared Accept; it goes
      # out (rebuilt) only once the owner authorizes.
      hold_pending_request(save_data, inbox_url, followee)
    else
      accept_follow_now(save_data, reply, inbox_url)
    end
  end

  defp locked_and_uninvited?(_save_data, nil), do: false

  defp locked_and_uninvited?(save_data, %Account{locked: true} = followee),
    do: not invited?(save_data, followee)

  defp locked_and_uninvited?(_save_data, _followee), do: false

  # FEP-bebd: a Follow carrying a valid invite (the code as its
  # `instrument`) skips the waiting room even when the account is locked.
  defp invited?(save_data, %Account{id: followee_id}) do
    instrument = get_in(save_data, ["follow", "instrument"])
    SukhiFedi.FollowInvites.invited?(followee_id, instrument)
  end

  defp accept_follow_now(save_data, reply, inbox_url) do
    insert_follow(save_data)
    maybe_notify_follow(save_data)

    followee_uri = save_data["followeeUri"]

    Oban.insert!(
      SukhiFedi.Oban,
      Oban.Job.new(
        %{raw_json: reply, inbox_url: inbox_url, actor_uri: followee_uri},
        worker: @delivery_worker,
        queue: @delivery_queue
      )
    )

    # Nudge the follower to refresh our cached actor (so their follower
    # count reflects us immediately instead of after their 24h TTL).
    maybe_enqueue_actor_update(followee_uri, inbox_url)

    # Replay our recent public posts to the new follower's inbox. Without
    # this they only see posts published after the Accept lands, which
    # means a quiet account looks empty on their server until we post
    # something new.
    maybe_backfill_recent_notes(followee_uri, inbox_url)
  end

  # Park a Follow aimed at a locked account. Idempotent on (followee,
  # follower) so a re-sent Follow doesn't pile up, and it notifies the
  # owner once so they know someone is waiting.
  defp hold_pending_request(save_data, inbox_url, %Account{id: followee_id}) do
    follow_data = save_data["follow"]
    follower_uri = follow_data && Extract.extract_uri(follow_data["actor"])

    if is_binary(follower_uri) do
      {:ok, _} =
        %FollowRequest{
          followee_id: followee_id,
          follower_uri: follower_uri,
          follow_activity: follow_data,
          follower_inbox: inbox_url
        }
        |> Repo.insert(
          on_conflict: :nothing,
          conflict_target: [:followee_id, :follower_uri]
        )

      maybe_notify_follow_request(followee_id, follower_uri)
    end

    :ok
  end

  defp maybe_notify_follow_request(followee_id, follower_uri) do
    with {:ok, %Account{id: from_id}} <- Resolve.resolve_or_ingest_actor(follower_uri) do
      Notifications.create(%{
        account_id: followee_id,
        from_account_id: from_id,
        type: "follow_request"
      })
    end

    :ok
  end

  @doc """
  Pending inbound follow requests for a locked account's owner. Returns
  `%{request_id, follower_uri, account}` rows; `account` is the hydrated
  follower (nil for an un-ingested or local-only follower, which the
  caller renders minimally from `follower_uri`).
  """
  def list_requests(followee_id) when is_integer(followee_id) do
    from(r in FollowRequest,
      left_join: a in Account,
      on: a.actor_uri == r.follower_uri,
      where: r.followee_id == ^followee_id,
      order_by: [desc: r.created_at],
      select: %{request_id: r.id, follower_uri: r.follower_uri, account: a}
    )
    |> Repo.all()
  end

  @doc """
  Owner authorizes the pending request from `follower_account_id`: deliver
  the (now real) Accept, turn it into an accepted follow, drop the request,
  and warm the follower up. Keyed by the follower's account id to match
  Mastodon's `POST /follow_requests/:account_id/authorize`.
  """
  def authorize(followee_id, follower_account_id) when is_integer(followee_id) do
    with uri when is_binary(uri) <- follower_uri_for(follower_account_id),
         %FollowRequest{} = req <- get_request_by_uri(followee_id, uri),
         %Account{} = followee <- Repo.get(Account, followee_id) do
      actor_uri = ActorJson.actor_uri(followee.username)
      deliver_follow_reply("Accept", actor_uri, req.follow_activity, req.follower_inbox)

      %Follow{follower_uri: req.follower_uri, followee_id: followee_id, state: "accepted"}
      |> Repo.insert(on_conflict: :nothing)

      Repo.delete(req)
      maybe_enqueue_actor_update(actor_uri, req.follower_inbox)
      maybe_backfill_recent_notes(actor_uri, req.follower_inbox)
      {:ok, req.follower_uri}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Owner rejects the pending request from `follower_account_id`."
  def reject(followee_id, follower_account_id) when is_integer(followee_id) do
    with uri when is_binary(uri) <- follower_uri_for(follower_account_id),
         %FollowRequest{} = req <- get_request_by_uri(followee_id, uri),
         %Account{} = followee <- Repo.get(Account, followee_id) do
      actor_uri = ActorJson.actor_uri(followee.username)
      deliver_follow_reply("Reject", actor_uri, req.follow_activity, req.follower_inbox)
      Repo.delete(req)
      {:ok, req.follower_uri}
    else
      _ -> {:error, :not_found}
    end
  end

  # The actor URI a follower account is known by: a remote's stored
  # `actor_uri`, or a local account's synthesized `/users/<u>` URL.
  defp follower_uri_for(account_id) do
    case Repo.get(Account, account_id) do
      %Account{actor_uri: uri} when is_binary(uri) and uri != "" -> uri
      %Account{domain: nil, username: u} -> ActorJson.actor_uri(u)
      _ -> nil
    end
  end

  defp get_request_by_uri(followee_id, follower_uri) do
    Repo.one(
      from(r in FollowRequest,
        where: r.followee_id == ^followee_id and r.follower_uri == ^follower_uri
      )
    )
  end

  # Build an Accept/Reject whose object is the original Follow and hand it
  # to the delivery node (which signs it) for the follower's inbox.
  defp deliver_follow_reply(type, actor_uri, follow_activity, inbox_url) do
    domain = SukhiFedi.Config.domain!()

    reply = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "https://#{domain}/activities/#{String.downcase(type)}/#{random_hex()}",
      "type" => type,
      "actor" => actor_uri,
      "object" => follow_activity
    }

    Oban.insert!(
      SukhiFedi.Oban,
      Oban.Job.new(
        %{raw_json: reply, inbox_url: inbox_url, actor_uri: actor_uri},
        worker: @delivery_worker,
        queue: @delivery_queue
      )
    )
  end

  defp random_hex, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  @doc "When we receive Accept(Follow) where the actor is a known relay, mark it accepted."
  def maybe_handle_relay_accept(%{"type" => "Accept", "actor" => actor_uri})
      when is_binary(actor_uri) do
    Relays.accept(actor_uri)
    :ok
  end

  def maybe_handle_relay_accept(_), do: :ok

  @doc """
  Inbound Accept(Follow): the remote followee accepted our outbound
  Follow. Flip the local Follow row from `pending` → `accepted` so
  home-timeline visibility kicks in.

  We match on the inner Follow's `actor` (= our local actor URI) and
  `object` (= remote followee URI, which maps to a shadow Account).
  If the Accept embeds only the Follow's URI (a string), we skip —
  we don't currently persist the outbound Follow's AP id.
  """
  def maybe_handle_follow_accept(%{
        "type" => "Accept",
        "object" => %{"type" => "Follow"} = inner
      }) do
    with follower_uri when is_binary(follower_uri) <- Extract.extract_uri(inner["actor"]),
         followee_uri when is_binary(followee_uri) <- Extract.extract_uri(inner["object"]),
         %Account{id: followee_id} <- Repo.get_by(Account, actor_uri: followee_uri) do
      from(f in Follow,
        where: f.follower_uri == ^follower_uri and f.followee_id == ^followee_id
      )
      |> Repo.update_all(set: [state: "accepted"])

      :ok
    else
      _ -> :ok
    end
  end

  def maybe_handle_follow_accept(_), do: :ok

  @doc "Undo(Follow): drop the follow row and nudge the ex-follower's actor cache."
  def undo_follow(actor_uri, inner) do
    followee_uri = Extract.extract_object_id(inner["object"])
    followee_id = followee_uri && Resolve.local_account_id_from_uri(followee_uri)

    if followee_id do
      from(f in Follow,
        where: f.follower_uri == ^actor_uri and f.followee_id == ^followee_id
      )
      |> Repo.delete_all()

      # Nudge the ex-follower to refresh our actor cache so its
      # follower count drops immediately instead of on the next
      # 24-hour TTL sweep. Heuristic inbox = `<actor>/inbox`;
      # works for Mastodon + fedify-based servers.
      maybe_enqueue_actor_update(followee_uri, actor_uri <> "/inbox")
    end

    :ok
  end

  defp insert_follow(%{"follow" => follow_data} = data) do
    followee_uri = data["followeeUri"]

    account =
      if followee_uri do
        username =
          followee_uri
          |> URI.parse()
          |> Map.get(:path, "")
          |> String.split("/")
          |> List.last()

        SukhiFedi.Accounts.by_local_username(username)
      else
        SukhiFedi.Accounts.by_local_username(data["followee_username"])
      end

    if account && follow_data do
      follower_uri = Extract.extract_uri(follow_data["actor"])

      if is_binary(follower_uri) do
        %Follow{
          follower_uri: follower_uri,
          followee_id: account.id,
          state: "accepted"
        }
        |> Repo.insert(on_conflict: :nothing)
      end
    end
  end

  defp insert_follow(_), do: :ok

  # Inbound `Follow` (already auto-accepted via save_and_reply) → follow
  # notification for the local followee.
  defp maybe_notify_follow(%{"follow" => follow_data} = data) do
    with %Account{id: followee_id} <- local_followee(data),
         follower_uri when is_binary(follower_uri) <- Extract.extract_uri(follow_data["actor"]),
         {:ok, %Account{id: from_id}} <- Resolve.resolve_or_ingest_actor(follower_uri) do
      Notifications.create(%{
        account_id: followee_id,
        from_account_id: from_id,
        type: "follow"
      })
    end

    :ok
  end

  defp maybe_notify_follow(_), do: :ok

  defp local_followee(%{"followeeUri" => uri}) when is_binary(uri) do
    username = Extract.actor_username(uri)
    SukhiFedi.Accounts.by_local_username(username)
  end

  defp local_followee(%{"followee_username" => u}) when is_binary(u) do
    SukhiFedi.Accounts.by_local_username(u)
  end

  defp local_followee(_), do: nil

  defp maybe_enqueue_actor_update(followee_uri, inbox_url)
       when is_binary(followee_uri) and is_binary(inbox_url) do
    username =
      followee_uri
      |> URI.parse()
      |> Map.get(:path, "")
      |> String.split("/")
      |> List.last()

    case SukhiFedi.Accounts.by_local_username(username) do
      %Account{} = account ->
        update_json = SukhiFedi.AP.ActorJson.build_update(account)

        Oban.insert!(
          SukhiFedi.Oban,
          Oban.Job.new(
            %{raw_json: update_json, inbox_url: inbox_url, actor_uri: followee_uri},
            worker: @delivery_worker,
            queue: @delivery_queue
          )
        )

      _ ->
        :ok
    end
  end

  defp maybe_enqueue_actor_update(_, _), do: :ok

  defp maybe_backfill_recent_notes(followee_uri, follower_inbox)
       when is_binary(followee_uri) and is_binary(follower_inbox) do
    username =
      followee_uri
      |> URI.parse()
      |> Map.get(:path, "")
      |> String.split("/")
      |> List.last()

    case SukhiFedi.Accounts.by_local_username(username) do
      %Account{id: account_id} ->
        from(n in Note,
          where: n.account_id == ^account_id and n.visibility == "public",
          order_by: [desc: n.created_at],
          limit: ^@backfill_limit,
          select: %{
            id: n.id,
            content: n.content,
            content_html: n.content_html,
            cw: n.cw,
            sensitive: n.sensitive,
            quote_of_ap_id: n.quote_of_ap_id,
            in_reply_to_ap_id: n.in_reply_to_ap_id
          }
        )
        |> Repo.all()
        |> Enum.each(fn n ->
          Outbox.enqueue(
            "sns.outbox.follow.backfill",
            "note",
            to_string(n.id),
            %{
              account_id: account_id,
              note_id: n.id,
              # What goes over the wire is HTML (AP `content`), so send the
              # rendered form — old rows have none and fall back as before.
              content: Note.html(n),
              cw: n.cw,
              sensitive: n.sensitive,
              quote_of_ap_id: n.quote_of_ap_id,
              in_reply_to_ap_id: n.in_reply_to_ap_id,
              follower_inbox: follower_inbox
            }
          )
        end)

      _ ->
        :ok
    end
  end

  defp maybe_backfill_recent_notes(_, _), do: :ok
end
