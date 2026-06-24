# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.CollectionController do
  @moduledoc """
  Serves followers, following, and outbox OrderedCollections for actor
  profiles. Required for FEP-8fcf (Followers Collection Synchronization)
  and for remote actors / timelines to list an account's public posts.
  """

  import Plug.Conn
  import Ecto.Query
  alias SukhiFedi.{Repo, Social}
  alias SukhiFedi.AP.{ActorJson, MediaSerialize}
  alias SukhiFedi.Schema.{Account, Note}
  alias SukhiFedi.Web.Auth.SessionCookie

  def followers(conn, _opts) do
    username = conn.path_params["name"]
    actor_uri = ActorJson.actor_uri(username)

    account = SukhiFedi.Accounts.by_local_username(username)

    if account do
      items = Social.list_followers(account.id)
      total = length(items)

      collection = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{actor_uri}/followers",
        "type" => "OrderedCollection",
        "totalItems" => total,
        "orderedItems" => items
      }

      conn
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, JSON.encode!(collection))
    else
      not_found(conn)
    end
  end

  # FEP-4ccd pending collections. Private by spec: only the account owner
  # may see who has asked to follow them, or whom they've asked to follow.
  # Gated on the first-party session cookie — anyone else gets 401, never a
  # list. Both are OrderedCollections of minimal Follow activities.
  def pending_followers(conn, _opts) do
    with_owned_account(conn, fn account, actor_uri ->
      items =
        account.id
        |> Social.list_pending_follower_uris()
        |> Enum.map(fn follower -> follow_activity(follower, actor_uri) end)

      pending_collection(conn, "#{actor_uri}/pendingFollowers", items)
    end)
  end

  def pending_following(conn, _opts) do
    with_owned_account(conn, fn _account, actor_uri ->
      items =
        actor_uri
        |> Social.list_pending_followee_uris()
        |> Enum.map(fn followee -> follow_activity(actor_uri, followee) end)

      pending_collection(conn, "#{actor_uri}/pendingFollowing", items)
    end)
  end

  defp with_owned_account(conn, fun) do
    username = conn.path_params["name"]

    case SessionCookie.account(conn) do
      %Account{username: ^username} = account ->
        fun.(account, ActorJson.actor_uri(username))

      _ ->
        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(401, JSON.encode!(%{"error" => "owner_only"}))
    end
  end

  defp follow_activity(actor, object) do
    %{"type" => "Follow", "actor" => actor, "object" => object}
  end

  defp pending_collection(conn, id, items) do
    collection = %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://purl.archive.org/socialweb/pending/1"
      ],
      "id" => id,
      "type" => "OrderedCollection",
      "totalItems" => length(items),
      "orderedItems" => items
    }

    conn
    |> put_resp_content_type("application/activity+json")
    |> send_resp(200, JSON.encode!(collection))
  end

  # FEP-bebd: dereference a follow invite as an `InviteCode` object. Public
  # — holding the (unguessable) code is the capability; the invited party's
  # server fetches this to show and echo it back as a Follow `instrument`.
  def invite(conn, _opts) do
    username = conn.path_params["name"]
    code = conn.path_params["code"]

    case SukhiFedi.FollowInvites.get(username, code) do
      {:ok, invite} ->
        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, JSON.encode!(SukhiFedi.FollowInvites.invite_object(invite, username)))

      _ ->
        not_found(conn)
    end
  end

  def outbox(conn, _opts) do
    username = conn.path_params["name"]
    actor_uri = ActorJson.actor_uri(username)

    account = SukhiFedi.Accounts.by_local_username(username)

    if account do
      notes =
        from(n in Note,
          where: n.account_id == ^account.id and n.visibility == "public",
          order_by: [desc: n.created_at]
        )
        |> Repo.all()
        |> Repo.preload(:media)

      items = Enum.map(notes, &note_to_create_activity(&1, actor_uri))

      collection = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{actor_uri}/outbox",
        "type" => "OrderedCollection",
        "totalItems" => length(items),
        "orderedItems" => items
      }

      conn
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, JSON.encode!(collection))
    else
      not_found(conn)
    end
  end

  defp note_to_create_activity(%Note{} = n, actor_uri) do
    note_ap_id = n.ap_id || "#{actor_uri}/notes/#{n.id}"
    activity_id = "#{note_ap_id}/activity"
    published = DateTime.to_iso8601(n.created_at)
    public_ns = "https://www.w3.org/ns/activitystreams#Public"

    %{
      "id" => activity_id,
      "type" => "Create",
      "actor" => actor_uri,
      "published" => published,
      "to" => [public_ns],
      "cc" => ["#{actor_uri}/followers"],
      "object" =>
        %{
          "id" => note_ap_id,
          "type" => "Note",
          "attributedTo" => actor_uri,
          "content" => n.content,
          "published" => published,
          "to" => [public_ns],
          "cc" => ["#{actor_uri}/followers"]
        }
        |> put_attachment(n.media)
    }
  end

  defp put_attachment(object, media) when is_list(media) and media != [] do
    Map.put(object, "attachment", MediaSerialize.ap_attachments(media))
  end

  defp put_attachment(object, _), do: object

  def following(conn, _opts) do
    username = conn.path_params["name"]
    actor_uri = ActorJson.actor_uri(username)

    account = SukhiFedi.Accounts.by_local_username(username)

    if account do
      follower_uri = actor_uri

      items =
        follower_uri
        |> Social.list_following()
        |> Enum.map(fn %{username: u} -> ActorJson.actor_uri(u) end)

      collection = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{actor_uri}/following",
        "type" => "OrderedCollection",
        "totalItems" => length(items),
        "orderedItems" => items
      }

      conn
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, JSON.encode!(collection))
    else
      not_found(conn)
    end
  end

  defp not_found(conn), do: send_resp(conn, 404, JSON.encode!(%{error: "not found"}))
end
