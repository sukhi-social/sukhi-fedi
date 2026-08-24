# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Relays do
  @moduledoc """
  Relay subscriptions. A relay is a fediverse service that fans public
  activity out between the servers that subscribe to it; joining one is
  how a small instance sees posts from authors nobody here follows yet.

  A subscription is an outbound `Follow` whose object is the literal
  `as:Public` URI, sent to the relay's inbox and signed by a local
  actor (the admin who added it — this server has no instance actor).
  The relay answers `Accept` (→ `accept/1`, state `accepted`) or
  `Reject` (→ `reject/1`); only `accepted` rows join the outbound
  fan-out (`get_active_inbox_urls/0`, read by the delivery node) and
  only their host is trusted as a relayed *source*
  (`accepted_host?/1`, read by `AP.Instructions`).

  Inbound relayed activity is *not* handled here: see
  `AP.Instructions.Relayed`, which re-fetches every relayed object from
  its origin rather than trusting the relay's copy.
  """

  import Ecto.Query

  alias SukhiFedi.AP.ActorJson
  alias SukhiFedi.AP.Instructions.Extract
  alias SukhiFedi.Federation.{ActorFetcher, UrlGuard}
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Relay}

  @public_ns "https://www.w3.org/ns/activitystreams#Public"

  # Delivery runs on a separate BEAM node with its own Oban supervisor
  # polling the :delivery queue; we reach its worker by name so the
  # gateway keeps no compile-time dependency on the delivery app.
  @delivery_worker "SukhiDelivery.Delivery.Worker"
  @delivery_queue "delivery"

  @doc """
  Subscribe to the relay whose actor lives at `url`, following as
  `admin`.

  The actor is fetched first: it decides the canonical `actor_uri` (the
  `id` the relay calls itself, which may differ from the URL typed in)
  and the inbox we deliver to. A relay we can't fetch is a relay we
  can't follow, so nothing is written in that case.
  """
  @spec subscribe(String.t(), Account.t()) ::
          {:ok, Relay.t()}
          | {:error, :unsafe_url | :unreachable | :no_inbox | :already_subscribed}
  def subscribe(url, %Account{} = admin) when is_binary(url) do
    if UrlGuard.safe?(url) do
      do_subscribe(url, admin)
    else
      {:error, :unsafe_url}
    end
  end

  defp do_subscribe(url, %Account{} = admin) do
    with {:ok, actor} <- fetch_relay_actor(url),
         {:ok, actor_uri, inbox_uri} <- relay_endpoints(actor, url),
         {:ok, relay} <- insert(actor_uri, inbox_uri, admin) do
      deliver(follow_activity(relay), relay)
      {:ok, relay}
    end
  end

  @doc """
  Unsubscribe: send the `Undo` that matches the original `Follow`, then
  drop the row. The row goes whether or not the Undo can be built — a
  subscription we can no longer address is one we should stop honouring
  locally either way.
  """
  @spec unsubscribe(integer() | String.t()) :: {:ok, Relay.t()} | {:error, :not_found}
  def unsubscribe(id) do
    case Repo.get(Relay, id) do
      nil ->
        {:error, :not_found}

      %Relay{} = relay ->
        case undo_activity(relay) do
          nil -> :ok
          activity -> deliver(activity, relay)
        end

        Repo.delete(relay)
    end
  end

  @doc "Mark a relay accepted (we received `Accept` from its actor)."
  def accept(actor_uri) when is_binary(actor_uri), do: set_state(actor_uri, "accepted")

  @doc "Mark a relay rejected (we received `Reject` from its actor)."
  def reject(actor_uri) when is_binary(actor_uri), do: set_state(actor_uri, "rejected")

  @doc "List all relays, newest first."
  def list do
    Repo.all(from(r in Relay, order_by: [desc: r.id]))
  end

  @doc "Return inbox URLs of all accepted relays."
  def get_active_inbox_urls do
    from(r in Relay, where: r.state == "accepted", select: r.inbox_uri)
    |> Repo.all()
  end

  @doc "Find a relay by actor URI."
  def get_by_actor_uri(actor_uri), do: Repo.get_by(Relay, actor_uri: actor_uri)

  @doc """
  True when `host` is the host of a relay we have an accepted
  subscription with. This is the *only* predicate that says "an
  activity signed by this host may be treated as relayed input"; the
  accepted set is a handful of rows, so it is read per activity rather
  than cached.
  """
  @spec accepted_host?(term()) :: boolean()
  def accepted_host?(host) when is_binary(host) and host != "" do
    # The inbox controller hands us a downcased host; do the same to the
    # stored side so a relay registered with a capitalised URL still matches.
    wanted = String.downcase(host)

    from(r in Relay, where: r.state == "accepted", select: r.actor_uri)
    |> Repo.all()
    |> Enum.any?(fn uri ->
      case Extract.actor_host(uri) do
        h when is_binary(h) -> String.downcase(h) == wanted
        nil -> false
      end
    end)
  end

  def accepted_host?(_), do: false

  # ── Private ──────────────────────────────────────────────────────────────

  defp set_state(actor_uri, state) do
    from(r in Relay, where: r.actor_uri == ^actor_uri)
    |> Repo.update_all(set: [state: state])
  end

  defp fetch_relay_actor(url) do
    case ActorFetcher.fetch(url) do
      {:ok, actor} when is_map(actor) -> {:ok, actor}
      _ -> {:error, :unreachable}
    end
  end

  # The relay's own `id` wins over the URL typed in (they differ when a
  # relay is addressed by an alias); its `inbox` is where the Follow
  # goes. `sharedInbox` is deliberately not preferred here — a relay's
  # subscription lives on its own inbox.
  defp relay_endpoints(actor, url) do
    actor_uri = Extract.extract_uri(actor["id"]) || url

    case Extract.extract_uri(actor["inbox"]) do
      inbox when is_binary(inbox) -> {:ok, actor_uri, inbox}
      _ -> {:error, :no_inbox}
    end
  end

  defp insert(actor_uri, inbox_uri, %Account{} = admin) do
    %Relay{}
    |> Relay.changeset(%{
      actor_uri: actor_uri,
      inbox_uri: inbox_uri,
      state: "pending",
      created_by_id: admin.id,
      follow_actor_uri: ActorJson.actor_uri(admin),
      follow_activity_id: mint_activity_id()
    })
    |> Repo.insert()
    |> case do
      {:ok, %Relay{} = relay} ->
        {:ok, relay}

      # `relay_endpoints/2` already guaranteed both required fields, so
      # the only changeset left that can fail is the unique actor_uri.
      {:error, _changeset} ->
        {:error, :already_subscribed}
    end
  end

  defp mint_activity_id do
    hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "https://#{SukhiFedi.Config.domain!()}/activities/follow/#{hex}"
  end

  defp follow_activity(%Relay{follow_actor_uri: actor, follow_activity_id: id}) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id,
      "type" => "Follow",
      "actor" => actor,
      "object" => @public_ns
    }
  end

  # A row from before `follow_actor_uri`/`follow_activity_id` existed
  # can't be undone over the wire — say so with nil rather than sending
  # an Undo the relay would not match.
  defp undo_activity(%Relay{follow_actor_uri: actor, follow_activity_id: id} = relay)
       when is_binary(actor) and is_binary(id) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => id <> "/undo",
      "type" => "Undo",
      "actor" => actor,
      "object" => follow_activity(relay) |> Map.delete("@context")
    }
  end

  defp undo_activity(%Relay{}), do: nil

  defp deliver(activity, %Relay{inbox_uri: inbox_uri, follow_actor_uri: actor_uri}) do
    Oban.insert!(
      SukhiFedi.Oban,
      Oban.Job.new(
        %{raw_json: activity, inbox_url: inbox_uri, actor_uri: actor_uri},
        worker: @delivery_worker,
        queue: @delivery_queue
      )
    )
  end
end
