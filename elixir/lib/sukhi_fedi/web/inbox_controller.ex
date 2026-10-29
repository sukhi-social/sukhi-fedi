# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.InboxController do
  import Plug.Conn

  require Logger

  alias SukhiFedi.AP.Ingest
  alias SukhiFedi.Web.SignedRequest
  alias SukhiFedi.Schema.Account

  # FEP-8fcf Collection-Synchronization format:
  #   collectionId="<uri>", url="<uri>", digest="<hex>"
  @sync_url_regex ~r/url="([^"]+)"/

  @follower_sync_worker "SukhiDelivery.Delivery.FollowerSyncWorker"
  @follower_sync_queue "federation"

  def user_inbox(conn, _opts) do
    handle_inbox(conn)
  end

  def shared_inbox(conn, _opts) do
    handle_inbox(conn)
  end

  defp handle_inbox(conn) do
    raw_json = conn.body_params
    raw_body = conn.assigns[:raw_body] || ""
    self_domain = Application.get_env(:sukhi_fedi, :domain) || conn.host
    sync_header = get_req_header(conn, "collection-synchronization") |> List.first()

    # A user-scoped inbox has a natural signer: the receiving account.
    # Shared inbox has none (no :name in the path) — fall back to any local
    # account's key, the same fallback outbound fetches already use for
    # this exact class of peer (`Accounts.signing_identity/0`: any local
    # actor's signature satisfies an auth-fetch check). Some peers
    # (Iceshrimp with authorized-fetch on, at least) 401 an unsigned GET for
    # the *signing key itself* — not just the activity's actor — so
    # verification needs this identity too, not only the inbox parse.
    sign_as = sign_as_for(conn) || SukhiFedi.Accounts.signing_identity()

    case SignedRequest.verify(conn, "POST", sign_as) do
      {:ok, %{signer_host: signer_host}} ->
        # Genuine original ⇒ archive to the `inbound` bucket off the hot
        # path (Q10), after the policy/proof gates and before the parser,
        # so a parse failure can't lose the record.
        headers = conn.req_headers |> Enum.into(%{}) |> Map.put("host", self_domain)
        archive = fn -> maybe_archive_inbound(raw_body, raw_json, headers, conn) end

        case Ingest.run(raw_json, signer_host,
               sign_as: sign_as,
               self_domain: self_domain,
               before_parse: archive,
               raw_body: raw_body
             ) do
          :accepted ->
            maybe_enqueue_follower_sync(raw_json, sync_header)
            send_resp(conn, 202, "")

          :suppressed ->
            send_resp(conn, 202, "")

          {:error, :proof_failed} ->
            send_resp(conn, 401, JSON.encode!(%{error: "object integrity proof failed"}))

          {:error, {:parse, reason}} ->
            send_resp(conn, 400, JSON.encode!(%{error: inspect(reason)}))
        end

      :unverified ->
        # Verification ran but the signature did not check out. This
        # `{:ok, %{"ok" => false}}` shape used to slip through `{:ok, _}`
        # and the activity executed unsigned — reject it now.
        send_resp(conn, 401, JSON.encode!(%{error: "signature verification failed"}))

      {:error, reason} ->
        send_resp(conn, 400, JSON.encode!(%{error: inspect(reason)}))
    end
  end

  defp maybe_archive_inbound("", _raw_json, _headers, _conn), do: :ok

  defp maybe_archive_inbound(raw_body, raw_json, headers, conn) when is_map(raw_json) do
    inbox_kind = if conn.path_params["name"], do: "user", else: "shared"

    case SukhiFedi.Federation.InboundArchive.enqueue(raw_body, raw_json, headers, inbox_kind) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        # The archive is the system of record for replay/rebuild. If we can't
        # even enqueue the job, this activity is about to be materialised and
        # answered 202 with no durable raw copy — make that loud rather than
        # swallowing it (the comment "archive before parse" only guards a parse
        # failure, not an enqueue failure).
        Logger.warning(
          "inbound archive enqueue failed (#{inspect(reason)}); activity processed " <>
            "but NOT archived: #{inspect(raw_json["id"])}"
        )

        :ok
    end
  end

  defp maybe_archive_inbound(_raw_body, _raw_json, _headers, _conn), do: :ok

  # When the inbox is user-scoped (`/users/:name/inbox`), return the
  # receiving account's signing key so Bun's `getActor` call can do an
  # authorized (signed) fetch of the remote actor. Required by servers
  # with Secure Mode / authorized-fetch turned on (Mastodon, Misskey).
  # Shared inbox has no :name, so this returns nil.
  defp sign_as_for(conn) do
    domain = Application.get_env(:sukhi_fedi, :domain) || conn.host

    with username when is_binary(username) <- conn.path_params["name"],
         %Account{private_key_jwk: priv, public_key_jwk: pub} when not is_nil(priv) <-
           SukhiFedi.Accounts.by_local_username(username) do
      %{
        keyId: "https://#{domain}/users/#{username}#main-key",
        privateJwk: priv,
        publicJwk: pub
      }
    else
      _ -> nil
    end
  end

  defp maybe_enqueue_follower_sync(_raw_json, nil), do: :ok

  defp maybe_enqueue_follower_sync(raw_json, sync_header) do
    actor_uri = Map.get(raw_json, "actor")
    domain = Application.get_env(:sukhi_fedi, :domain)

    # FEP-8fcf reconciliation only makes sense for a *remote* sender telling
    # us about its own followers collection. Our own activities are HTTP-
    # delivered to local followers' inboxes (with a sync header attached for
    # shared-inbox dedup), so they arrive back here with actor = a local URI.
    # Reconciling on those would wipe the local actor's own follow edges.
    with true <- is_binary(actor_uri),
         false <- is_binary(domain) and String.starts_with?(actor_uri, "https://#{domain}/"),
         [_, collection_url] <- Regex.run(@sync_url_regex, sync_header) do
      Oban.insert(
        SukhiFedi.Oban,
        Oban.Job.new(
          %{actor_uri: actor_uri, collection_url: collection_url},
          worker: @follower_sync_worker,
          queue: @follower_sync_queue
        )
      )
    end

    :ok
  end
end
