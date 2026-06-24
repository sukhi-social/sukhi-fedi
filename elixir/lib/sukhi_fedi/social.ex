# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Social do
  @moduledoc """
  Follow / unfollow / relationship queries. Reachable from the api
  plugin node via `SukhiApi.GatewayRpc.call(SukhiFedi.Social, :fun, [args])`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SukhiFedi.{Outbox, Repo}
  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Schema.{Account, AccountNote, Follow}

  # ── reads ─────────────────────────────────────────────────────────────────

  @doc """
  Followers of `account_id`, resolved to account projections.

  `follows` stores the follower side as a bare `follower_uri` — it may
  point at a remote actor (or a local user) and never carried a FK. We
  resolve each URI back to its `accounts` row so the Mastodon view can
  render a real profile (correct `acct`, avatar, …) instead of leaking
  the raw URI: local rows by username, remote shadow rows by
  `actor_uri`. A URI with no matching row falls through as
  `%{actor_uri: uri}` for the caller to render minimally.
  """
  def list_followers(account_id, _opts \\ []) do
    from(f in Follow,
      where: f.followee_id == ^account_id and f.state == "accepted",
      select: f.follower_uri
    )
    |> Repo.all()
    |> resolve_follower_uris()
  end

  defp resolve_follower_uris([]), do: []

  defp resolve_follower_uris(uris) do
    local_prefix = "https://#{SukhiFedi.Config.domain!()}/users/"

    {local_uris, remote_uris} =
      Enum.split_with(uris, &String.starts_with?(&1, local_prefix))

    local_usernames = Enum.map(local_uris, &String.replace_prefix(&1, local_prefix, ""))

    by_uri =
      from(a in Account,
        where:
          (is_nil(a.domain) and a.username in ^local_usernames) or
            a.actor_uri in ^remote_uris,
        select: %{
          id: a.id,
          username: a.username,
          domain: a.domain,
          display_name: a.display_name,
          summary: a.summary,
          emojis: a.emojis,
          actor_uri: a.actor_uri,
          avatar_url: a.avatar_url,
          banner_url: a.banner_url,
          locked: a.locked,
          is_bot: a.is_bot,
          is_admin: a.is_admin,
          created_at: a.created_at
        }
      )
      |> Repo.all()
      |> Map.new(fn a -> {canonical_actor_uri(a, local_prefix), a} end)

    Enum.map(uris, fn uri -> Map.get(by_uri, uri, %{actor_uri: uri}) end)
  end

  defp canonical_actor_uri(%{domain: nil, username: username}, local_prefix),
    do: local_prefix <> username

  defp canonical_actor_uri(%{actor_uri: actor_uri}, _local_prefix), do: actor_uri

  @doc """
  Returns a compact projection of the accounts the caller follows — one
  JOIN query, no N+1. Public-safe fields only (no key material).
  """
  def list_following(follower_uri, _opts \\ []) do
    from(f in Follow,
      join: a in Account,
      on: a.id == f.followee_id,
      where: f.follower_uri == ^follower_uri and f.state == "accepted",
      # Same projection as the followers list: the Mastodon account view
      # needs `domain` + `actor_uri` to render a remote followee as
      # "user@host" with its real URL. Without them it falls back to a
      # bare local handle and the profile link 404s.
      select: %{
        id: a.id,
        username: a.username,
        domain: a.domain,
        display_name: a.display_name,
        summary: a.summary,
        emojis: a.emojis,
        actor_uri: a.actor_uri,
        avatar_url: a.avatar_url,
        banner_url: a.banner_url,
        locked: a.locked,
        is_bot: a.is_bot,
        is_admin: a.is_admin,
        created_at: a.created_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Actor URIs whose Follow of `account_id` is still pending — the inbound
  side of FEP-4ccd's pendingFollowers (a locked account's unanswered
  follow requests). Just the URIs; the caller wraps each in a minimal
  Follow activity.
  """
  def list_pending_follower_uris(account_id) do
    from(f in Follow,
      where: f.followee_id == ^account_id and f.state == "pending",
      select: f.follower_uri
    )
    |> Repo.all()
  end

  @doc """
  Canonical actor URIs that `follower_uri` has asked to follow but which
  haven't sent an Accept yet — the outbound side (FEP-4ccd
  pendingFollowing).
  """
  def list_pending_followee_uris(follower_uri) do
    local_prefix = "https://#{SukhiFedi.Config.domain!()}/users/"

    from(f in Follow,
      join: a in Account,
      on: a.id == f.followee_id,
      where: f.follower_uri == ^follower_uri and f.state == "pending",
      select: %{domain: a.domain, username: a.username, actor_uri: a.actor_uri}
    )
    |> Repo.all()
    |> Enum.map(&canonical_actor_uri(&1, local_prefix))
  end

  # ── follow / unfollow ────────────────────────────────────────────────────

  @doc """
  Local user `follower` requests to follow account id `target_id`.

  Local target ⇒ inserted as `accepted` synchronously (no federation
  round-trip, no outbox event). Remote target ⇒ inserted as `pending`
  and `sns.outbox.follow.requested` is enqueued; the row flips to
  `accepted` when the remote's `Accept(Follow)` arrives through the
  inbox (`SukhiFedi.AP.Instructions.maybe_handle_follow_accept/1`).

  Idempotent: a duplicate follow returns the existing row.
  """
  @spec request_follow(Account.t(), integer()) ::
          {:ok, Follow.t()} | {:error, :self_follow | :not_found | term()}
  def request_follow(%Account{id: same}, target_id) when same == target_id,
    do: {:error, :self_follow}

  def request_follow(%Account{} = follower, target_id) when is_integer(target_id) do
    case Repo.get(Account, target_id) do
      nil ->
        {:error, :not_found}

      %Account{} = target ->
        actor_uri = local_actor_uri(follower)

        case existing_follow(actor_uri, target_id) do
          nil -> insert_follow_with_outbox(follower, actor_uri, target)
          %Follow{} = f -> {:ok, f}
        end
    end
  end

  defp insert_follow_with_outbox(%Account{id: follower_id} = _follower, actor_uri, %Account{} = target) do
    # Local target ⇒ no federation round-trip needed. Skip the outbox
    # event entirely and stamp the follow as `accepted` so home-timeline
    # visibility kicks in immediately. Remote target ⇒ start in `pending`
    # and wait for the remote's Accept(Follow) (handled by
    # `AP.Instructions.maybe_handle_follow_accept/1`).
    local_target? = is_nil(target.domain)

    multi =
      Multi.new()
      |> Multi.insert(
        :follow,
        %Follow{}
        |> Ecto.Changeset.change(%{
          follower_uri: actor_uri,
          followee_id: target.id,
          state: if(local_target?, do: "accepted", else: "pending")
        })
      )

    multi =
      if local_target? do
        multi
      else
        Outbox.enqueue_multi(
          multi,
          :outbox_event,
          "sns.outbox.follow.requested",
          "follow",
          & &1.follow.id,
          fn %{follow: f} ->
            %{
              follow_id: f.id,
              follower_uri: f.follower_uri,
              followee_id: f.followee_id,
              followee_username: target.username
            }
          end
        )
      end

    multi
    |> Repo.transaction()
    |> case do
      {:ok, %{follow: f}} ->
        if local_target? do
          SukhiFedi.Notifications.create(%{
            account_id: target.id,
            from_account_id: follower_id,
            type: "follow"
          })
        end

        {:ok, f}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Local user `follower` unfollows account id `target_id`.

  Returns `{:ok, follow}` (the deleted row) on success, or
  `{:error, :not_found}` if no follow existed.

  Emits `sns.outbox.follow.undone` so the delivery node can later send
  an outbound `Undo(Follow)` activity.
  """
  @spec unfollow(Account.t(), integer()) :: {:ok, Follow.t()} | {:error, :not_found | term()}
  def unfollow(%Account{} = follower, target_id) when is_integer(target_id) do
    actor_uri = local_actor_uri(follower)

    case existing_follow(actor_uri, target_id) do
      nil ->
        {:error, :not_found}

      %Follow{} = f ->
        target = Repo.get(Account, target_id)
        local_target? = match?(%Account{domain: nil}, target)

        multi = Multi.new() |> Multi.delete(:follow, f)

        multi =
          if local_target? do
            multi
          else
            Outbox.enqueue_multi(
              multi,
              :outbox_event,
              "sns.outbox.follow.undone",
              "follow",
              & &1.follow.id,
              fn %{follow: f} ->
                %{
                  follow_id: f.id,
                  follower_uri: f.follower_uri,
                  followee_id: f.followee_id
                }
              end
            )
          end

        multi
        |> Repo.transaction()
        |> case do
          {:ok, %{follow: f}} -> {:ok, f}
          {:error, _step, reason, _} -> {:error, reason}
        end
    end
  end

  # ── relationships ────────────────────────────────────────────────────────

  @doc """
  Compute Mastodon Relationship rows for `viewer` × `target_ids`.

  Single query: pulls every relevant Follow row in one shot. Block /
  mute / domain_block dimensions are wired to the `:moderation` addon
  if loaded; absent there, they default to `false` (no false positives,
  no false negatives — the addon is the source of truth).

  Returns a list shaped for `SukhiApi.Views.MastodonRelationship`.
  """
  @spec list_relationships(Account.t(), [integer()]) :: [map()]
  def list_relationships(%Account{} = viewer, target_ids) when is_list(target_ids) do
    target_ids = target_ids |> Enum.map(&SukhiFedi.Coercion.parse_id/1) |> Enum.reject(&is_nil/1)

    if target_ids == [] do
      []
    else
      actor_uri = local_actor_uri(viewer)

      following_set =
        from(f in Follow,
          where: f.follower_uri == ^actor_uri and f.followee_id in ^target_ids,
          select: {f.followee_id, f.state}
        )
        |> Repo.all()
        |> Map.new()

      followed_by_set =
        case load_target_uris(target_ids) do
          [] ->
            MapSet.new()

          uri_pairs ->
            uris = Enum.map(uri_pairs, fn {_id, uri} -> uri end)

            uris_following_viewer =
              from(f in Follow,
                where: f.follower_uri in ^uris and f.followee_id == ^viewer.id,
                select: f.follower_uri
              )
              |> Repo.all()
              |> MapSet.new()

            uri_pairs
            |> Enum.filter(fn {_id, uri} -> MapSet.member?(uris_following_viewer, uri) end)
            |> Enum.map(fn {id, _uri} -> id end)
            |> MapSet.new()
        end

      # Real moderation state, so the client reflects what actually took
      # effect (the block POST response renders this very map).
      blocking_set = MapSet.new(Moderation.blocked_target_ids(viewer.id))
      muting_set = MapSet.new(Moderation.muted_target_ids(viewer.id))
      blocked_by_block_set = MapSet.new(Moderation.blocked_by_ids(viewer.id, target_ids))

      blocked_domains =
        from(a in Account, where: a.id in ^target_ids and not is_nil(a.domain), select: a.domain)
        |> Repo.all()
        |> Enum.uniq()
        |> Enum.filter(&Moderation.instance_blocked?/1)
        |> MapSet.new()

      target_domain =
        from(a in Account, where: a.id in ^target_ids, select: {a.id, a.domain})
        |> Repo.all()
        |> Map.new()

      # The viewer's private memo about each target (local-only, never
      # federated). One query, id-keyed, so the render stays a map lookup.
      note_map = account_notes_for(viewer.id, target_ids)

      Enum.map(target_ids, fn id ->
        state = Map.get(following_set, id)
        muting? = MapSet.member?(muting_set, id)
        domain = Map.get(target_domain, id)

        %{
          id: id,
          following: state == "accepted",
          requested: state == "pending",
          followed_by: MapSet.member?(followed_by_set, id),
          showing_reblogs: true,
          notifying: false,
          blocking: MapSet.member?(blocking_set, id),
          blocked_by: MapSet.member?(blocked_by_block_set, id),
          muting: muting?,
          muting_notifications: muting?,
          domain_blocking: is_binary(domain) and MapSet.member?(blocked_domains, domain),
          endorsed: false,
          note: Map.get(note_map, id, "")
        }
      end)
    end
  end

  @doc """
  Set (or clear) the viewer's private note about `target_id`.

  Local-only and never federated: a label the author keeps about another
  account, shown only to them alongside the target's real name. An empty
  string clears it. Upsert on the (author, target) pair so there is at
  most one note per target. Returns `{:ok, note}` or `{:error, reason}`.
  """
  @spec set_account_note(Account.t(), integer(), String.t()) ::
          {:ok, AccountNote.t()} | {:error, :not_found | term()}
  def set_account_note(%Account{id: author_id}, target_id, comment)
      when is_integer(target_id) and is_binary(comment) do
    if Repo.exists?(from(a in Account, where: a.id == ^target_id)) do
      %AccountNote{}
      |> AccountNote.changeset(%{
        author_account_id: author_id,
        target_account_id: target_id,
        comment: comment
      })
      |> Repo.insert(
        on_conflict: {:replace, [:comment, :updated_at]},
        conflict_target: [:author_account_id, :target_account_id]
      )
    else
      {:error, :not_found}
    end
  end

  defp account_notes_for(author_id, target_ids) do
    from(n in AccountNote,
      where: n.author_account_id == ^author_id and n.target_account_id in ^target_ids,
      select: {n.target_account_id, n.comment}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp existing_follow(actor_uri, target_id) do
    Repo.get_by(Follow, follower_uri: actor_uri, followee_id: target_id)
  end

  defp load_target_uris(target_ids) do
    domain = SukhiFedi.Config.domain!()

    from(a in Account,
      where: a.id in ^target_ids,
      select: {a.id, a.username, a.actor_uri}
    )
    |> Repo.all()
    |> Enum.map(fn
      {id, _u, actor_uri} when is_binary(actor_uri) -> {id, actor_uri}
      {id, username, _} -> {id, "https://#{domain}/users/#{username}"}
    end)
  end

  defp local_actor_uri(%Account{username: u}) do
    domain = SukhiFedi.Config.domain!()
    "https://#{domain}/users/#{u}"
  end
end
