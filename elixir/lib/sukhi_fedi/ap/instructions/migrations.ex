# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Instructions.Migrations do
  @moduledoc """
  Inbound account migration: a `Move` activity from an `old` identity to
  a `new` one (Mastodon-standard account migration).

  When `old` (an account a local user follows) announces it has moved to
  `new`, we re-point each local follow `old → new`: follow the new
  identity and `Undo` the follow of the old one. Both rides ride the
  transactional outbox so the outbound `Follow` / `Undo(Follow)` are
  durable (CODE_STYLE §4).

  ## Consent

  A `Move` is signed by `old`, so it can only prove that *old* wants to
  leave — never that *new* agreed to receive `old`'s followers. The
  bidirectional consent both Mastodon and we require is that the **new**
  actor lists `old` in its `alsoKnownAs`. We fetch the new actor fresh
  (the Move's payload is not authority for what `new` claims) and check
  its mirrored `aliases`. The check is one pure predicate,
  `bidirectional_consent?/2`, in the style of
  `Instructions.trusted_inline_origin?/2` — never inlined at a call site
  (CODE_STYLE §3).
  """

  import Ecto.Query

  alias SukhiFedi.Accounts
  alias Ecto.Multi
  alias SukhiFedi.AP.Instructions.{Extract, Resolve}
  alias SukhiFedi.{Outbox, Repo}
  alias SukhiFedi.Schema.{Account, Follow}

  @doc """
  Inbound `Move`: re-point local follows from `old` to `new` once the new
  actor consents (lists `old` in `alsoKnownAs`).

  Returns `:ok` in every branch — a Move we can't act on (no resolvable
  target, missing consent, no local followers) is a no-op, not an error.
  """
  def maybe_handle_move(%{"type" => "Move", "actor" => old, "target" => target}) do
    with old_uri when is_binary(old_uri) <- Extract.extract_uri(old),
         new_uri when is_binary(new_uri) <- Extract.extract_object_id(target),
         %Account{id: old_id} = old_account <- Accounts.by_actor_uri(old_uri),
         {:ok, %Account{} = new_account} <- Resolve.resolve_or_ingest_actor(new_uri),
         true <- bidirectional_consent?(old_uri, new_account) do
      # The Move is the authoritative "I have moved" signal, signed by old.
      # Stamp the old row's `moved_to_uri` so every profile quietly renders
      # the truthful "moved to @new" state — no notification, no number.
      mark_moved(old_account, new_uri)
      repoint_follows(old_id, new_account)
    else
      _ -> :ok
    end

    :ok
  end

  def maybe_handle_move(_), do: :ok

  @doc """
  The single consent predicate for account migration: the **new** actor
  must list `old_uri` among its `alsoKnownAs` (mirrored into `aliases`).

  Pure — takes the old actor's URI and the fetched new account, returns a
  boolean — so the Move handler reads it once and never re-spells the
  rule. Extend *this* clause, not a call site, if the consent shape grows.
  """
  @spec bidirectional_consent?(String.t(), Account.t()) :: boolean()
  def bidirectional_consent?(old_uri, %Account{aliases: aliases}) when is_binary(old_uri),
    do: is_list(aliases) and old_uri in aliases

  def bidirectional_consent?(_old_uri, _new_account), do: false

  defp mark_moved(%Account{} = old_account, new_uri) do
    {:ok, _} =
      old_account
      |> Ecto.Changeset.change(%{moved_to_uri: new_uri})
      |> Repo.update()

    :ok
  end

  # Re-point every accepted local follow of `old` to the `new` identity,
  # in one transaction: insert the follow to `new` (+ its outbound Follow
  # event) and delete the follow of `old` (+ its outbound Undo event). A
  # local target needs no federation round-trip, so it's stamped
  # `accepted` and skips the outbox — same split as `Social.request_follow/2`.
  defp repoint_follows(old_id, %Account{} = new_account) do
    local_prefix = "https://#{SukhiFedi.Config.domain!()}/users/"

    local_follows =
      Repo.all(
        from f in Follow,
          where:
            f.followee_id == ^old_id and f.state == "accepted" and
              like(f.follower_uri, ^(local_prefix <> "%"))
      )

    Enum.each(local_follows, fn follow -> repoint_one(follow, new_account) end)
  end

  defp repoint_one(%Follow{} = old_follow, %Account{} = new_account) do
    # A follower who already follows `new` only needs the old edge undone;
    # a fresh insert here would conflict (and a duplicate Follow would go
    # out). So the new Follow is added only when it isn't already there.
    already? =
      Repo.exists?(
        from f in Follow,
          where: f.follower_uri == ^old_follow.follower_uri and f.followee_id == ^new_account.id
      )

    Multi.new()
    |> maybe_insert_follow(already?, old_follow, new_account)
    |> Multi.delete(:old_follow, old_follow)
    |> enqueue_undo(old_follow)
    |> Repo.transaction()

    :ok
  end

  # New edge: stamped `accepted` for a local target (no round-trip),
  # `pending` for a remote one (flips on the new server's Accept). A remote
  # target also gets an outbound Follow event so the new server records the
  # edge; a local one skips it — same split as `Social.request_follow/2`.
  defp maybe_insert_follow(multi, true, _old_follow, _new_account), do: multi

  defp maybe_insert_follow(multi, false, %Follow{} = old_follow, %Account{} = new_account) do
    local_target? = is_nil(new_account.domain)

    multi =
      Multi.insert(
        multi,
        :follow,
        Ecto.Changeset.change(%Follow{}, %{
          follower_uri: old_follow.follower_uri,
          followee_id: new_account.id,
          state: if(local_target?, do: "accepted", else: "pending")
        })
      )

    if local_target? do
      multi
    else
      Outbox.enqueue_multi(
        multi,
        :outbox_follow,
        "sns.outbox.follow.requested",
        "follow",
        & &1.follow.id,
        fn %{follow: f} ->
          %{
            follow_id: f.id,
            follower_uri: f.follower_uri,
            followee_id: f.followee_id,
            followee_username: new_account.username
          }
        end
      )
    end
  end

  # The follow of `old` is always undone on the wire: if `old` was remote
  # the Undo(Follow) tells that server to drop the edge; a delivery to a
  # local actor is a harmless no-op. Never silently drop the federated
  # follow state (the irreversible-loss rule — FEDERATION.md §9).
  defp enqueue_undo(multi, %Follow{} = old_follow) do
    Outbox.enqueue_multi(
      multi,
      :outbox_undo,
      "sns.outbox.follow.undone",
      "follow",
      fn _ -> old_follow.id end,
      fn _ ->
        %{
          follow_id: old_follow.id,
          follower_uri: old_follow.follower_uri,
          followee_id: old_follow.followee_id
        }
      end
    )
  end
end
