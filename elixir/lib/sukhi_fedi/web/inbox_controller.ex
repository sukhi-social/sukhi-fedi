# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.InboxController do
  import Plug.Conn

  require Logger

  alias SukhiFedi.AP.Instructions
  alias SukhiFedi.Federation.FedifyClient
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
    # Bind the signature base's `host` to our canonical public host rather
    # than the proxy-forwarded Host header (cloudflared/kamal can rewrite
    # it to an internal value). The remote signed `host: <domain>` when it
    # delivered to https://<domain>/inbox.
    headers = conn.req_headers |> Enum.into(%{}) |> Map.put("host", self_domain)
    url = public_url(conn)
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

    verify_payload =
      case sign_as do
        nil -> %{raw: raw_body, headers: headers, method: "POST", url: url}
        sign_as -> %{raw: raw_body, headers: headers, method: "POST", url: url, signAs: sign_as}
      end

    inbox_payload =
      case sign_as do
        nil -> %{raw: raw_json, selfDomain: self_domain}
        sign_as -> %{raw: raw_json, signAs: sign_as, selfDomain: self_domain}
      end

    case FedifyClient.verify(verify_payload) do
      {:ok, %{"ok" => true} = verify_result} ->
        cond do
          actor_policy(raw_json) == :reject ->
            # Domain is suspended (`:reject`). Accept-and-drop (202) so the
            # blocked peer can't tell it's being filtered — but run no handlers
            # and don't archive. A `:silence` domain is *not* rejected here: it
            # falls through to materialize, and `Moderation.silenced_author_ids/0`
            # keeps its notes off the home/public surfaces downstream.
            send_resp(conn, 202, "")

          not proof_acceptable?(raw_json) ->
            # FEP-8b32: the body carries an Object Integrity Proof we can
            # check and it does not check out. Downgrade safety — a broken
            # proof must not silently fall through to HTTP-signature-only
            # handling.
            send_resp(conn, 401, JSON.encode!(%{error: "object integrity proof failed"}))

          true ->
            # The signature checks out. Record *who* signed (the key owner's
            # host) so Instructions can refuse to act on an activity whose
            # claimed `actor` lives on a different host than the signer.
            signer_host = signer_host(verify_result)

            # Genuine original ⇒ archive to the `inbound` bucket off the hot
            # path (Q10), right after verify and before the instruction
            # parser, so a parse failure can't lose the record.
            maybe_archive_inbound(raw_body, raw_json, headers, conn)

            case FedifyClient.inbox(inbox_payload) do
              {:ok, instruction} ->
                Instructions.execute(instruction, signer_host)
                maybe_enqueue_follower_sync(raw_json, sync_header)
                send_resp(conn, 202, "")

              {:error, reason} ->
                send_resp(conn, 400, JSON.encode!(%{error: inspect(reason)}))
            end
        end

      {:ok, _unverified} ->
        # Verification ran but the signature did not check out. This
        # `{:ok, %{"ok" => false}}` shape used to slip through `{:ok, _}`
        # and the activity executed unsigned — reject it now.
        send_resp(conn, 401, JSON.encode!(%{error: "signature verification failed"}))

      {:error, reason} ->
        send_resp(conn, 400, JSON.encode!(%{error: inspect(reason)}))
    end
  end

  # FEP-8b32 gate: a present-and-checkable proof must verify; absence (or
  # a cryptosuite we don't implement) falls back to the HTTP signature,
  # which already authenticated the request above.
  defp proof_acceptable?(raw_json) when is_map(raw_json) do
    case SukhiFedi.Fedi.Oip.verify_inbound(raw_json) do
      :ok ->
        true

      :no_proof ->
        true

      :no_checkable_proof ->
        Logger.info("inbox: only unsupported-cryptosuite proofs on #{raw_json["id"]}; relying on the HTTP signature")
        true

      {:error, reason} ->
        Logger.warning("inbox: object integrity proof failed (#{inspect(reason)}) on #{raw_json["id"]}")
        false
    end
  end

  defp proof_acceptable?(_), do: true

  # The instance policy for the activity's actor host (the one place that
  # decision lives is `Moderation.instance_policy/1`). `:reject` is the only
  # value the gate acts on; `:silence`/`:pass` materialize.
  defp actor_policy(raw_json) when is_map(raw_json) do
    case raw_json |> Map.get("actor") |> actor_uri() |> uri_host() do
      host when is_binary(host) -> SukhiFedi.Addons.Moderation.instance_policy(host)
      _ -> :pass
    end
  end

  defp actor_policy(_), do: :pass

  defp actor_uri(uri) when is_binary(uri), do: uri
  defp actor_uri(%{"id" => id}) when is_binary(id), do: id
  defp actor_uri(_), do: nil

  # Host of the actor that actually signed the request (the HTTP-signature
  # key's owner; fall back to the keyId host). nil when neither is present
  # or parseable.
  defp signer_host(%{"owner" => owner}) when is_binary(owner), do: uri_host(owner)
  defp signer_host(%{"keyId" => key_id}) when is_binary(key_id), do: uri_host(key_id)
  defp signer_host(_), do: nil

  defp uri_host(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: h} when is_binary(h) and h != "" -> String.downcase(h)
      _ -> nil
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

  # Reconstruct the public URL the remote signer signed against, even
  # when cloudflared (or any reverse proxy) has rewritten Host to an
  # internal value like `gateway:4000`.
  defp public_url(conn) do
    domain = Application.get_env(:sukhi_fedi, :domain) || conn.host
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    "https://#{domain}#{conn.request_path}#{query}"
  end

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
