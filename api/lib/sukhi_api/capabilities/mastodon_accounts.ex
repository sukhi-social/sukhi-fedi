# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonAccounts do
  @moduledoc """
  Mastodon `/api/v1/accounts/*` read surface plus
  `update_credentials` and `relationships`. Authenticated routes
  require an OAuth bearer token; public reads (`:id`, `lookup`,
  `:id/statuses`, `:id/followers`, `:id/following`) do not.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.{GatewayRpc, Multipart, Pagination, StatusHydration}
  alias SukhiApi.Views.{MastodonAccount, MastodonRelationship}

  # avatar/header の inline 上限。/api/v1/media と揃える。
  @max_upload_bytes 8 * 1024 * 1024

  @impl true
  def routes do
    [
      {:post, "/api/v1/accounts", &create/1, scope: "read"},
      {:get, "/api/v1/accounts/verify_credentials", &verify_credentials/1,
       scope: "read:accounts"},
      {:patch, "/api/v1/accounts/update_credentials", &update_credentials/1,
       scope: "write:accounts"},
      {:get, "/api/v1/accounts/lookup", &lookup/1},
      {:get, "/api/v1/accounts/relationships", &relationships/1, scope: "read:follows"},
      {:get, "/api/v1/follow_requests", &follow_requests/1, scope: "read:follows"},
      {:post, "/api/v1/follow_requests/:id/authorize", &authorize_follow_request/1,
       scope: "write:follows"},
      {:post, "/api/v1/follow_requests/:id/reject", &reject_follow_request/1,
       scope: "write:follows"},
      {:get, "/api/v1/follow_invites", &list_follow_invites/1, scope: "read:follows"},
      {:post, "/api/v1/follow_invites", &create_follow_invite/1, scope: "write:follows"},
      {:delete, "/api/v1/follow_invites/:code", &delete_follow_invite/1, scope: "write:follows"},
      {:post, "/api/v1/accounts/:id/note", &note/1, scope: "write:accounts"},
      {:get, "/api/v1/accounts/:id", &show/1},
      {:get, "/api/v1/accounts/:id/statuses", &statuses/1},
      {:get, "/api/v1/accounts/:id/followers", &followers/1},
      {:get, "/api/v1/accounts/:id/following", &following/1}
    ]
  end

  # ── create (signup) ──────────────────────────────────────────────────────

  @doc """
  Mastodon `POST /api/v1/accounts`. Invite-code gated. The bearer must
  be a `client_credentials` token (the SPA registers via `/api/v1/apps`
  then exchanges for an app token); on success a user-bound access
  token is minted under that same app and returned in the same shape
  as `/oauth/token`.
  """
  def create(req) do
    %{current_app: app} = req[:assigns]
    attrs = decode_create_attrs(req)

    case app do
      nil ->
        ok(403, %{error: "client_credentials_required"})

      %{id: app_id} ->
        case GatewayRpc.call(SukhiFedi.LocalAccounts, :create, [attrs]) do
          {:ok, {:ok, %{id: account_id}}} ->
            # Mastodon 同様、明示が無ければ署名に使った app token の
            # granted scopes を継ぐ。固定 "read" に落とすと write 系が
            # 全部 403 になる(新規ユーザーが follow できなかった原因)。
            scopes = attrs["scopes"] || Enum.join(req[:assigns][:scopes] || ["read"], " ")

            case GatewayRpc.call(SukhiFedi.OAuth, :issue_initial_token, [app_id, account_id, scopes]) do
              {:ok, {:ok, token}} ->
                ok(200, token)

              _ ->
                ok(500, %{error: "token_mint_failed"})
            end

          {:ok, {:error, :invite_missing}} ->
            ok(422, %{error: "invite_code_required"})

          {:ok, {:error, :invite_invalid}} ->
            ok(422, %{error: "invite_invalid"})

          {:ok, {:error, :invite_used}} ->
            ok(422, %{error: "invite_used"})

          {:ok, {:error, :invite_expired}} ->
            ok(422, %{error: "invite_expired"})

          {:ok, {:error, :password_too_short}} ->
            ok(422, %{error: "password_too_short"})

          # The signed mailbox proof (from /signup/email/confirm) was
          # missing, garbled, or older than its 20 minutes — the SPA
          # sends the user back to the code step.
          {:ok, {:error, :email_proof_invalid}} ->
            ok(422, %{error: "email_proof_invalid"})

          {:ok, {:error, {:validation, details}}} ->
            ok(422, %{error: "validation_failed", details: details})

          {:error, :not_connected} ->
            ok(503, %{error: "gateway_not_connected"})

          {:error, {:badrpc, reason}} ->
            ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})

          _ ->
            ok(500, %{error: "internal_error"})
        end
    end
  end

  defp decode_create_attrs(req) do
    headers = req[:headers] || []
    ct = content_type(headers)

    cond do
      String.contains?(ct, "application/json") ->
        case JSON.decode(req[:body] || "") do
          {:ok, %{} = m} -> m
          _ -> %{}
        end

      String.contains?(ct, "application/x-www-form-urlencoded") ->
        URI.decode_query(req[:body] || "")

      true ->
        %{}
    end
  end

  # ── verify_credentials ───────────────────────────────────────────────────

  def verify_credentials(req) do
    %{current_account: account, scopes: scopes} = req[:assigns]

    case account do
      nil ->
        # client_credentials grant — no end-user identity
        ok(403, %{error: "this endpoint requires a user-bound token"})

      %{} = a ->
        counts = counts_for(a.id)
        ok(200, MastodonAccount.render_credential(a, counts, scopes))
    end
  end

  # ── update_credentials ───────────────────────────────────────────────────

  def update_credentials(req) do
    %{current_account: account} = req[:assigns]

    case account do
      nil ->
        ok(403, %{error: "this endpoint requires a user-bound token"})

      %{id: id} ->
        case decode_update_attrs(req, id) do
          {:ok, attrs} ->
            do_update_credentials(req, id, attrs)

          {:error, status, body} ->
            ok(status, body)
        end
    end
  end

  defp do_update_credentials(req, id, attrs) do
    case GatewayRpc.call(SukhiFedi.Accounts, :update_credentials, [id, attrs]) do
      {:ok, {:ok, updated}} ->
        counts = counts_for(updated.id)
        ok(200, MastodonAccount.render_credential(updated, counts, req[:assigns][:scopes]))

      {:ok, {:error, :not_found}} ->
        ok(404, %{error: "account_not_found"})

      {:ok, {:error, {:validation, errors}}} ->
        ok(422, %{error: "validation_failed", details: errors})

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      {:error, {:badrpc, reason}} ->
        ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})

      _ ->
        ok(500, %{error: "internal_error"})
    end
  end

  # multipart の場合は avatar/header を先に Media pipeline に通して
  # URL を取り、それを attrs に詰める。テキスト項目(display_name,
  # note, locked, bot, discoverable, indexable)は fields からそのまま
  # 渡す。SPA は常に multipart で来るが、JSON / urlencoded も Mastodon
  # 互換のため受け付ける。
  defp decode_update_attrs(req, account_id) do
    headers = req[:headers] || []
    ct = content_type(headers)

    cond do
      String.contains?(ct, "multipart/form-data") ->
        decode_multipart(req[:body] || "", ct, account_id)

      String.contains?(ct, "application/json") ->
        case JSON.decode(req[:body] || "") do
          {:ok, %{} = m} -> {:ok, m}
          _ -> {:ok, %{}}
        end

      String.contains?(ct, "application/x-www-form-urlencoded") ->
        {:ok, URI.decode_query(req[:body] || "")}

      true ->
        {:ok, %{}}
    end
  end

  defp decode_multipart(body, ct, account_id) do
    case Multipart.parse_multifile(body, ct, max_file_bytes: @max_upload_bytes) do
      {:ok, %{fields: fields, files: files}} ->
        with {:ok, avatar_url} <- maybe_upload(files["avatar"], account_id),
             {:ok, banner_url} <- maybe_upload(files["header"], account_id) do
          attrs =
            fields
            |> Map.take(["display_name", "note", "locked", "bot", "discoverable", "indexable"])
            |> maybe_put("avatar_url", avatar_url)
            |> maybe_put("banner_url", banner_url)
            |> maybe_put("fields", decode_fields(fields["fields"]))

          {:ok, attrs}
        end

      {:error, :file_too_large} ->
        {:error, 413, %{error: "file_too_large"}}

      {:error, reason} ->
        {:error, 400, %{error: "bad_multipart", detail: to_string(reason)}}
    end
  end

  defp maybe_upload(nil, _account_id), do: {:ok, nil}

  defp maybe_upload(%{filename: filename, content_type: ct, bytes: bytes}, account_id) do
    attrs = %{"filename" => filename, "content_type" => ct}

    case GatewayRpc.call(SukhiFedi.Addons.Media, :create_from_upload, [
           account_id,
           bytes,
           attrs
         ]) do
      {:ok, {:ok, media}} ->
        {:ok, media.url}

      {:ok, {:error, :empty_upload}} ->
        {:error, 422, %{error: "empty_upload"}}

      {:ok, {:error, :file_too_large}} ->
        {:error, 413, %{error: "file_too_large"}}

      {:ok, {:error, {:validation, errors}}} ->
        {:error, 422, %{error: "validation_failed", details: errors}}

      {:ok, {:error, reason}} ->
        {:error, 422, %{error: inspect(reason)}}

      {:error, :not_connected} ->
        {:error, 503, %{error: "gateway_not_connected"}}

      {:error, {:badrpc, reason}} ->
        {:error, 503, %{error: "gateway_rpc_failed", detail: inspect(reason)}}

      _ ->
        {:error, 500, %{error: "internal_error"}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Profile fields ride as a JSON-encoded array string in one form part
  # (`[{"name":..,"value":..}, ...]`); the SPA is the only writer. A
  # missing part means "don't touch fields" → nil so `maybe_put` skips
  # it; an empty array clears them. The list itself is sanitized and
  # capped by the gateway changeset (`Account.cast_fields/1`).
  defp decode_fields(nil), do: nil

  defp decode_fields(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> nil
    end
  end

  defp decode_fields(_), do: nil

  # ── lookup ───────────────────────────────────────────────────────────────

  def lookup(req) do
    q = parse_query(req[:query])
    acct = q["acct"] || ""
    resolve? = q["resolve"] in ["true", "1"]

    case GatewayRpc.call(SukhiFedi.Accounts, :lookup_by_acct, [acct, [resolve: resolve?]]) do
      {:ok, {:ok, account}} ->
        ok(200, MastodonAccount.render(account, counts_for(account.id)))

      {:ok, {:error, :not_found}} ->
        ok(404, %{error: "account_not_found"})

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      {:error, {:badrpc, reason}} ->
        ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})
    end
  end

  # ── show ─────────────────────────────────────────────────────────────────

  def show(req) do
    id = req[:path_params]["id"]

    case GatewayRpc.call(SukhiFedi.Accounts, :get_account, [id]) do
      {:ok, {:ok, account}} ->
        ok(200, MastodonAccount.render(account, counts_for(account.id)))

      {:ok, {:error, :not_found}} ->
        ok(404, %{error: "account_not_found"})

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      {:error, {:badrpc, reason}} ->
        ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})
    end
  end

  # ── statuses ─────────────────────────────────────────────────────────────

  def statuses(req) do
    id = req[:path_params]["id"]
    viewer = req[:assigns][:current_account]

    with {:ok, int_id} <- parse_int(id),
         opts = parse_status_opts(req[:query]) |> Map.put(:viewer_id, viewer && viewer.id),
         {:ok, notes} when is_list(notes) <-
           GatewayRpc.call(SukhiFedi.Accounts, :list_statuses, [int_id, Map.to_list(opts)]) do
      body = StatusHydration.many(notes, viewer)
      headers = [{"content-type", "application/json"}]

      headers =
        case Pagination.link_header(
               "/api/v1/accounts/#{id}/statuses",
               notes,
               & &1.id,
               opts
             ) do
          nil -> headers
          link -> [link | headers]
        end

      {:ok, %{status: 200, body: JSON.encode!(body), headers: headers}}
    else
      {:error, :bad_int} ->
        ok(400, %{error: "invalid_id"})

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      {:error, {:badrpc, reason}} ->
        ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})

      _ ->
        ok(500, %{error: "internal_error"})
    end
  end

  defp parse_status_opts(q) do
    base = Pagination.parse_opts(q)
    parsed = parse_query(q)

    base
    |> Map.put(:exclude_replies, parsed["exclude_replies"] in ["true", "1"])
    |> Map.put(:exclude_reblogs, parsed["exclude_reblogs"] in ["true", "1"])
    |> Map.put(:only_media, parsed["only_media"] in ["true", "1"])
    |> Map.put(:pinned, parsed["pinned"] in ["true", "1"])
    # Sukhi extension: the profile's Articles tab. Only notes with a title
    # (inbound `Article`s); never interleaves boosts.
    |> Map.put(:only_articles, parsed["only_articles"] in ["true", "1"])
  end

  # ── followers / following ────────────────────────────────────────────────

  def followers(req) do
    id = req[:path_params]["id"]

    with {:ok, int_id} <- parse_int(id),
         {:ok, items} when is_list(items) <-
           GatewayRpc.call(SukhiFedi.Social, :list_followers, [int_id]) do
      ok(200, Enum.map(items, &render_follower/1))
    else
      {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
      {:error, :not_connected} -> ok(503, %{error: "gateway_not_connected"})
      {:error, {:badrpc, r}} -> ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})
      _ -> ok(500, %{error: "internal_error"})
    end
  end

  def following(req) do
    id = req[:path_params]["id"]

    with {:ok, int_id} <- parse_int(id),
         {:ok, %{} = account} <-
           account_by_id(int_id),
         actor_uri = local_actor_uri(account.username),
         {:ok, items} when is_list(items) <-
           GatewayRpc.call(SukhiFedi.Social, :list_following, [actor_uri]) do
      ok(200, Enum.map(items, fn item -> MastodonAccount.render(item, %{}) end))
    else
      {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
      {:error, :not_found} -> ok(404, %{error: "account_not_found"})
      {:error, :not_connected} -> ok(503, %{error: "gateway_not_connected"})
      {:error, {:badrpc, r}} -> ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})
      _ -> ok(500, %{error: "internal_error"})
    end
  end

  defp account_by_id(int_id) do
    case GatewayRpc.call(SukhiFedi.Accounts, :get_account, [int_id]) do
      {:ok, {:ok, a}} -> {:ok, a}
      {:ok, {:error, :not_found}} -> {:error, :not_found}
      {:error, e} -> {:error, e}
    end
  end

  # The gateway resolves each follower URI to a real account row where it
  # can; those arrive as projection maps carrying `:id`. A URI it couldn't
  # resolve (remote actor not yet ingested, or a deleted local row) arrives
  # as `%{actor_uri: uri}` and gets the minimal shape below.
  defp render_follower(%{id: _} = account), do: MastodonAccount.render(account, %{})
  defp render_follower(%{actor_uri: uri}), do: uri_only_account(uri)

  defp uri_only_account(uri) do
    # Followers list returns AP URIs (some of which may be remote and
    # not yet hydrated locally). Surface a minimal Account-shaped JSON
    # carrying just the id (= URI) and url. Mastodon clients tolerate
    # missing fields; PR-N can fan out webfinger lookups for richer data.
    %{
      id: uri,
      acct: uri,
      username: extract_username(uri),
      display_name: extract_username(uri),
      url: uri,
      uri: uri,
      avatar: nil,
      header: nil,
      followers_count: 0,
      following_count: 0,
      statuses_count: 0,
      created_at: nil,
      note: "",
      bot: false,
      locked: false
    }
  end

  defp extract_username(uri) when is_binary(uri) do
    uri |> URI.parse() |> Map.get(:path, "") |> to_string() |> Path.basename()
  end

  defp extract_username(_), do: ""

  # ── relationships ────────────────────────────────────────────────────────

  def relationships(req) do
    %{current_account: viewer} = req[:assigns]
    ids = extract_ids(req[:query])

    case viewer do
      nil ->
        ok(403, %{error: "this endpoint requires a user-bound token"})

      %{} = v ->
        case GatewayRpc.call(SukhiFedi.Social, :list_relationships, [v, ids]) do
          {:ok, rels} when is_list(rels) ->
            ok(200, Enum.map(rels, &MastodonRelationship.render/1))

          {:error, :not_connected} ->
            ok(503, %{error: "gateway_not_connected"})

          {:error, {:badrpc, r}} ->
            ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

          _ ->
            ok(500, %{error: "internal_error"})
        end
    end
  end

  # ── follow requests (locked-account inbound approval, FEP-bebd kin) ───────

  @doc "Mastodon `GET /api/v1/follow_requests`: accounts waiting for approval."
  def follow_requests(req) do
    case req[:assigns][:current_account] do
      nil ->
        ok(403, %{error: "this endpoint requires a user-bound token"})

      %{id: vid} ->
        case GatewayRpc.call(SukhiFedi.AP.Instructions.Follows, :list_requests, [vid]) do
          {:ok, rows} when is_list(rows) ->
            ok(200, rows |> Enum.map(&request_account/1) |> Enum.reject(&is_nil/1))

          {:error, :not_connected} -> ok(503, %{error: "gateway_not_connected"})
          {:error, {:badrpc, r}} -> ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})
          _ -> ok(500, %{error: "internal_error"})
        end
    end
  end

  @doc "Mastodon `POST /api/v1/follow_requests/:id/authorize`."
  def authorize_follow_request(req), do: act_on_request(req, :authorize)

  @doc "Mastodon `POST /api/v1/follow_requests/:id/reject`."
  def reject_follow_request(req), do: act_on_request(req, :reject)

  defp act_on_request(req, action) do
    id = req[:path_params]["id"]
    viewer = req[:assigns][:current_account]

    with %{id: vid} <- viewer,
         {:ok, int_id} <- parse_int(id),
         {:ok, {:ok, _uri}} <-
           GatewayRpc.call(SukhiFedi.AP.Instructions.Follows, action, [vid, int_id]) do
      ok(200, relationship_after(viewer, int_id))
    else
      nil -> ok(403, %{error: "this endpoint requires a user-bound token"})
      {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
      {:ok, {:error, :not_found}} -> ok(404, %{error: "follow_request_not_found"})
      {:error, :not_connected} -> ok(503, %{error: "gateway_not_connected"})
      {:error, {:badrpc, r}} -> ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})
      _ -> ok(500, %{error: "internal_error"})
    end
  end

  # A request row carries the hydrated follower account; render it. A row
  # whose follower we never ingested has no stable id to act on, so it's
  # dropped here (rare — a follower is ingested when its Follow notifies us).
  defp request_account(%{account: %{id: _} = a}), do: MastodonAccount.render(a, %{})
  defp request_account(_), do: nil

  defp relationship_after(viewer, account_id) do
    case GatewayRpc.call(SukhiFedi.Social, :list_relationships, [viewer, [account_id]]) do
      {:ok, [rel | _]} -> MastodonRelationship.render(rel)
      _ -> %{}
    end
  end

  # ── follow invites (FEP-bebd) ─────────────────────────────────────────────
  # sukhi-specific: a locked account mints invite codes to skip its own
  # approval queue. The SPA turns a `code` into a shareable link from origin.

  def list_follow_invites(req) do
    with_owner(req, fn vid ->
      case GatewayRpc.call(SukhiFedi.FollowInvites, :list, [vid]) do
        {:ok, invites} when is_list(invites) ->
          ok(200, Enum.map(invites, fn i -> %{code: i.code} end))

        other ->
          gateway_error(other)
      end
    end)
  end

  def create_follow_invite(req) do
    with_owner(req, fn vid ->
      case GatewayRpc.call(SukhiFedi.FollowInvites, :mint, [vid]) do
        {:ok, {:ok, invite}} -> ok(200, %{code: invite.code})
        other -> gateway_error(other)
      end
    end)
  end

  def delete_follow_invite(req) do
    code = req[:path_params]["code"]

    with_owner(req, fn vid ->
      case GatewayRpc.call(SukhiFedi.FollowInvites, :revoke, [vid, code]) do
        {:ok, {:ok, _}} -> ok(200, %{})
        {:ok, {:error, :not_found}} -> ok(404, %{error: "invite_not_found"})
        other -> gateway_error(other)
      end
    end)
  end

  defp with_owner(req, fun) do
    case req[:assigns][:current_account] do
      %{id: vid} -> fun.(vid)
      _ -> ok(403, %{error: "this endpoint requires a user-bound token"})
    end
  end

  defp gateway_error({:error, :not_connected}), do: ok(503, %{error: "gateway_not_connected"})

  defp gateway_error({:error, {:badrpc, r}}),
    do: ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

  defp gateway_error(_), do: ok(500, %{error: "internal_error"})

  # Mastodon allows id[]=1&id[]=2 or id=1,2,3. We must decode the raw
  # query string ourselves: `URI.decode_query` folds repeated keys into
  # one map entry, so `id[]=1&id[]=2&id[]=3` would collapse to just "3"
  # and only the last account in a followers/following list would get a
  # relationship (→ the follow button showed on the last row only).
  # `URI.query_decoder` preserves every pair.
  defp extract_ids(query) when is_binary(query) do
    query
    |> URI.query_decoder()
    |> Enum.flat_map(fn
      {"id[]", v} -> String.split(v || "", ",", trim: true)
      {"id", v} -> String.split(v || "", ",", trim: true)
      _ -> []
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(40)
    |> Enum.map(fn s ->
      case Integer.parse(s) do
        {n, ""} -> n
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_ids(_), do: []

  # ── note (private memo) ──────────────────────────────────────────────────

  # Mastodon `POST /api/v1/accounts/:id/note`, body `{comment}`. A private,
  # local-only label the viewer keeps about the target; an empty/absent
  # comment clears it. Returns the updated Relationship — its `note` field
  # now carries what was just set.
  def note(req) do
    %{current_account: viewer} = req[:assigns]
    id = req[:path_params]["id"]

    case viewer do
      nil ->
        ok(403, %{error: "this endpoint requires a user-bound token"})

      %{} = v ->
        with {:ok, int_id} <- parse_int(id),
             comment = decode_note_comment(req),
             {:ok, {:ok, _saved}} <-
               GatewayRpc.call(SukhiFedi.Social, :set_account_note, [v, int_id, comment]) do
          rel =
            case GatewayRpc.call(SukhiFedi.Social, :list_relationships, [v, [int_id]]) do
              {:ok, [r]} -> r
              _ -> %{id: int_id}
            end

          ok(200, MastodonRelationship.render(rel))
        else
          {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
          {:ok, {:error, :not_found}} -> ok(404, %{error: "account_not_found"})
          {:error, :not_connected} -> ok(503, %{error: "gateway_not_connected"})
          {:error, {:badrpc, r}} -> ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})
          _ -> ok(500, %{error: "internal_error"})
        end
    end
  end

  defp decode_note_comment(req) do
    headers = req[:headers] || []
    ct = content_type(headers)

    params =
      cond do
        String.contains?(ct, "application/json") ->
          case JSON.decode(req[:body] || "") do
            {:ok, %{} = m} -> m
            _ -> %{}
          end

        String.contains?(ct, "application/x-www-form-urlencoded") ->
          URI.decode_query(req[:body] || "")

        true ->
          %{}
      end

    to_string(params["comment"] || "")
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp counts_for(account_id) when is_integer(account_id) do
    case GatewayRpc.call(SukhiFedi.Accounts, :counts_for, [account_id]) do
      {:ok, %{} = m} -> m
      _ -> %{followers: 0, following: 0, statuses: 0}
    end
  end

  defp local_actor_uri(username) do
    domain = SukhiApi.Config.domain!()
    "https://#{domain}/users/#{username}"
  end

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_int}
    end
  end

  defp parse_int(n) when is_integer(n), do: {:ok, n}
  defp parse_int(_), do: {:error, :bad_int}

  defp parse_query(nil), do: %{}
  defp parse_query(""), do: %{}
  defp parse_query(q) when is_binary(q), do: URI.decode_query(q)

  defp content_type(headers) do
    Enum.find_value(headers, "", fn {k, v} ->
      if String.downcase(to_string(k)) == "content-type", do: to_string(v), else: nil
    end)
  end

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
