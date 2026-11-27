# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Delivery.FollowersSync do
  @moduledoc """
  FEP-8fcf: Followers Collection Synchronization.

  Computes the Collection-Synchronization header for outbound shared-inbox
  deliveries, and reconciles stale local follow records when we receive
  the header from a remote server. Header parsing lives on the gateway
  (InboxController) since it's a pure regex and the parsed result only
  drives the enqueue of a follow-up Oban job.
  """

  import Ecto.Query
  alias SukhiDelivery.Repo
  alias SukhiDelivery.Schema.Follow

  @doc """
  Extract the authoritative item list from a fetched collection body. Only an
  inline `items`/`orderedItems` list counts: a paginated collection keeps its
  members under `first`/`next`, so a body with neither key is "could not
  enumerate", returned as `{:error, :no_inline_items}` — never as an empty list.
  Treating non-inline as `[]` is exactly what would let reconcile wipe live
  follow edges.
  """
  @spec items_from_body(map()) :: {:ok, list()} | {:error, :no_inline_items}
  def items_from_body(body) when is_map(body) do
    cond do
      is_list(body["items"]) -> {:ok, body["items"]}
      is_list(body["orderedItems"]) -> {:ok, body["orderedItems"]}
      true -> {:error, :no_inline_items}
    end
  end

  @doc """
  Compute a SHA-256 digest (lowercase hex) of the sorted follower URIs for a
  local actor's followers collection.
  """
  def compute_digest(actor_uri) do
    username = username_from_uri(actor_uri)
    account = SukhiDelivery.Accounts.by_local_username(username)

    if account do
      follower_uris =
        from(f in Follow,
          where: f.followee_id == ^account.id and f.state == "accepted",
          select: f.follower_uri,
          order_by: f.follower_uri
        )
        |> Repo.all()

      :crypto.hash(:sha256, Enum.join(follower_uris, "\n"))
      |> Base.encode16(case: :lower)
    else
      nil
    end
  end

  @doc """
  Build the value for the Collection-Synchronization header for outbound
  shared-inbox deliveries by a local actor.
  """
  def header_value(actor_uri) do
    case compute_digest(actor_uri) do
      nil ->
        nil

      digest ->
        followers_uri = "#{actor_uri}/followers"
        digest_uri = "#{actor_uri}/followers#digest"
        ~s(collectionId="#{followers_uri}", url="#{digest_uri}", digest="#{digest}")
    end
  end

  @doc """
  Reconcile local follow records for a remote actor whose followers collection
  digest we received. Removes stale follows not present in the remote collection.
  """
  # An empty list is the ambiguous case: it could mean "genuinely zero of your
  # users follow me" or "I couldn't enumerate them" (a paginated/partial fetch
  # that surfaced no inline items). Pruning a real follow edge is irreversible
  # — it's locally-authored relationship state with no archive and no remote to
  # refetch — so we refuse to delete on an empty result. A genuinely-stale edge
  # just lingers until the remote sends an explicit Undo(Follow); that's the
  # cheap, recoverable side of the trade.
  def reconcile(_sender_actor_uri, []), do: :ok

  def reconcile(sender_actor_uri, collection_items) when is_list(collection_items) do
    domain = Application.get_env(:sukhi_delivery, :domain)
    local_prefix = "https://#{domain}/users/"

    # The sender is a remote actor; `collection_items` is the @our-domain
    # subset of *its* followers collection (the URIs of our local users it
    # believes follow it). We reconcile our local "local-user follows sender"
    # edges against that list. A local sender has no actor_uri row, so this
    # no-ops — we never touch a local actor's own follow edges.
    sender = SukhiDelivery.Accounts.by_actor_uri(sender_actor_uri)

    if sender do
      local_follows =
        from(f in Follow,
          where:
            f.followee_id == ^sender.id and f.state == "accepted" and
              like(f.follower_uri, ^(local_prefix <> "%")),
          select: %{id: f.id, follower_uri: f.follower_uri}
        )
        |> Repo.all()

      stale_ids =
        for %{id: id, follower_uri: uri} <- local_follows,
            uri not in collection_items,
            do: id

      unless stale_ids == [] do
        from(f in Follow, where: f.id in ^stale_ids) |> Repo.delete_all()
      end
    end

    :ok
  end

  defp username_from_uri(uri) do
    uri |> URI.parse() |> Map.get(:path, "") |> String.split("/") |> List.last()
  end
end
