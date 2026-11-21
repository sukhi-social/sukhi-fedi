# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.OAuth do
  @moduledoc """
  OAuth 2.0 server endpoints. `token` / `revoke` are mounted on `/oauth/*`
  (not `/api/v1/*`) per Mastodon convention; the gateway router has a
  `match "/oauth/*_"` block that forwards them here.

      POST  /oauth/token                    grant_type ∈ {authorization_code, refresh_token, client_credentials}
      POST  /oauth/revoke                   RFC 7009; idempotent
      GET   /api/v1/sukhi/oauth/authorize   what the browser's session should be shown (JSON)
      POST  /api/v1/sukhi/oauth/authorize   the person said yes → the redirect that carries the code (JSON)

  **There is no page here.** `/oauth/authorize` — the account picker, the
  consent form, the errors — is a web front's (web-next). It asks this
  capability *what to show* and draws it; the decision (who is signed in, is
  this a first-party redirect, does the app exist, is the scope allowed) stays
  on this side, in one place, next to the code it mints.

  The browser's own cookies (`session_token`, `session_tokens`) are what the
  front forwards — these two routes read them, not a bearer.

  GET answers `200 {"decision": …}`, one of:

      "login"     nobody is signed in — send them to the sign-in page, then back
      "pick"      several accounts are signed in — `accounts: [{id, username}]`;
                  ask again with `choose=<id>`
      "consent"   a third-party app asks — `app: {name, client_id}`, `scopes: [...]`
      "redirect"  go to `location` (the code is already minted: a first-party
                  app, where asking "may I?" of one's own server is only form)

  A `choose=<id>` that is answered carries the re-ordered `Set-Cookie`s on that
  one response (it is the only chance to hand them over). Anything wrong is a
  non-2xx `{"error": code, "error_description": …}`.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc

  @gateway SukhiFedi.OAuth
  @session_cookie SukhiFedi.Web.Auth.SessionCookie

  @impl true
  def routes do
    [
      {:get, "/api/v1/sukhi/oauth/authorize", &decide/1},
      {:post, "/api/v1/sukhi/oauth/authorize", &approve/1},
      {:post, "/oauth/token", &token/1},
      {:post, "/oauth/revoke", &revoke/1}
    ]
  end

  # ── GET /api/v1/sukhi/oauth/authorize ────────────────────────────────────

  def decide(req) do
    params = parse_query(req[:query])
    client_id = params["client_id"]
    redirect_uri = params["redirect_uri"] || ""
    scope = params["scope"] || "read"
    state = params["state"] || ""
    response_type = params["response_type"] || "code"
    choose = params["choose"]
    headers = req[:headers] || []
    # 同名 session_token が複数あっても全部を候補にする(古い方に
    # 引きずられない)。extra(session_tokens)はその後ろに並べる。
    token_candidates = session_tokens_from_cookies(headers)
    primary_token = List.first(token_candidates)
    extra_tokens = extra_tokens_from_cookies(headers) ++ Enum.drop(token_candidates, 1)

    cond do
      response_type != "code" ->
        error(400, "unsupported_response_type", "only response_type=code is supported")

      is_nil(client_id) or client_id == "" ->
        error(400, "invalid_request", "missing client_id")

      is_binary(choose) ->
        # 「このアカウントで続ける」を選んだ直後。選んだ方を主に並べ替えた
        # Set-Cookie を付けたまま、その場で consent(または first-party の
        # 即発行)へ進む ── 一度リダイレクトを挟むと、まだ2アカウントとも
        # 有効なままなのでピッカーがもう一度出てしまう。
        sessions = resolve_sessions(primary_token, extra_tokens)

        case choose_target(sessions, choose) do
          nil ->
            # 選んだものがもう無い(期限切れ等)。選び直してもらう。
            pick(sessions)

          target ->
            case GatewayRpc.run(@session_cookie, :layout_for_promote, [sessions, target.account.id]) do
              {:ok, {new_primary, new_extras}} ->
                authorize_with_session(
                  target.account,
                  client_id,
                  redirect_uri,
                  scope,
                  state,
                  session_set_cookie_headers(new_primary, new_extras)
                )

              {:unavailable, why} ->
                unavailable(why)
            end
        end

      true ->
        case resolve_sessions(primary_token, extra_tokens) do
          # ログインしていない人に consent 画面を見せない。ログインが済んだら
          # 同じ問いに戻ってこられるよう、戻す先は呼び手(front)が持つ。
          [] ->
            decision(%{decision: "login"})

          [%{account: account}] ->
            authorize_with_session(account, client_id, redirect_uri, scope, state)

          # 2 個以上サインインしてるときだけ、consent の手前に一枚
          # 「どのアカウントで続ける?」を挟む。1個しか無い人には今まで
          # 通り何も見えない。
          sessions ->
            pick(sessions)
        end
    end
  end

  defp choose_target(sessions, choose) do
    case Integer.parse(choose) do
      {account_id, ""} -> Enum.find(sessions, &(&1.account.id == account_id))
      _ -> nil
    end
  end

  defp pick(sessions) do
    decision(%{
      decision: "pick",
      accounts: Enum.map(sessions, fn %{account: a} -> %{id: a.id, username: a.username} end)
    })
  end

  # 自分のサーバの SPA に「自分が自分を許可する?」を聞くのは形式で
  # しかないので、redirect_uri が自ホストなら consent を出さずに即
  # code を発行する。外部の Mastodon クライアント等(別ホスト)が来た
  # ときは従来どおり consent。`extra_headers` はピッカーで選んだ直後
  # だけ乗る、並べ替えた Set-Cookie(このリクエストの応答が最初にそれを
  # 運ぶ唯一の機会)。
  defp authorize_with_session(account, client_id, redirect_uri, scope, state, extra_headers \\ []) do
    case GatewayRpc.run(@gateway, :find_app_by_client_id, [client_id]) do
      {:ok, app} ->
        if first_party?(redirect_uri) do
          mint_and_redirect(app, account, redirect_uri, scope, state, extra_headers)
        else
          decision(
            %{
              decision: "consent",
              app: %{name: app.name, client_id: app.client_id},
              scopes: scope_names(scope)
            },
            extra_headers
          )
        end

      {:error, :not_found} ->
        error(404, "invalid_client", "unknown client_id")

      {:unavailable, why} ->
        unavailable(why)
    end
  end

  defp mint_and_redirect(app, account, redirect_uri, scope, state, extra_headers) do
    case GatewayRpc.run(@gateway, :create_authorization_code, [
           app,
           account,
           %{redirect_uri: redirect_uri, scopes: scope, state: state}
         ]) do
      {:ok, %{code: code, state: returned_state}} ->
        redirect(redirect_uri, [code: code, state: returned_state], extra_headers)

      {:error, :invalid_redirect_uri} ->
        error(400, "invalid_redirect_uri", "redirect_uri does not match registered URIs")

      {:error, :invalid_scope} ->
        error(400, "invalid_scope", "requested scope exceeds the app's allowed scopes")

      {:unavailable, why} ->
        unavailable(why)
    end
  end

  defp first_party?(redirect_uri) when is_binary(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{host: host} when is_binary(host) ->
        host == SukhiApi.Config.domain!() |> strip_port()

      _ ->
        false
    end
  end

  defp first_party?(_), do: false

  defp strip_port(domain), do: domain |> String.split(":", parts: 2) |> hd()

  # scope は空白区切り (Mastodon 互換)。"read write follow" や
  # "read:statuses write:statuses" のような形で来る。言い換え(その人の
  # ことばへ)は front の仕事 ── ここは名前を並べるだけ。
  defp scope_names(scope) do
    scope
    |> to_string()
    |> String.split([" ", "+"], trim: true)
    |> Enum.uniq()
  end

  # ── POST /api/v1/sukhi/oauth/authorize ───────────────────────────────────

  def approve(req) do
    # 同意フォームの submit は front が受け、JSON にして渡してくる。
    # (PluginPlug が body_params を JSON に再エンコードして渡してくる
    # 形も同じ。直接呼ばれた古いテスト等のために form 形式への
    # フォールバックも残す。)
    body = decode_request_body(req)
    client_id = body["client_id"]
    redirect_uri = body["redirect_uri"] || ""
    scope = body["scope"] || "read"
    state = body["state"]
    token_candidates = session_tokens_from_cookies(req[:headers] || [])

    cond do
      is_nil(client_id) or client_id == "" ->
        error(400, "invalid_request", "missing client_id")

      true ->
        do_approve(client_id, redirect_uri, scope, state, token_candidates)
    end
  end

  defp do_approve(client_id, redirect_uri, scope, state, token_candidates) do
    with {:ok, account} <- resolve_session_any(token_candidates),
         {:ok, app} <- GatewayRpc.run(@gateway, :find_app_by_client_id, [client_id]),
         {:ok, %{code: code, state: returned_state}} <-
           GatewayRpc.run(@gateway, :create_authorization_code, [
             app,
             account,
             %{redirect_uri: redirect_uri, scopes: scope, state: state}
           ]) do
      redirect(redirect_uri, code: code, state: returned_state)
    else
      {:error, :no_session} ->
        error(401, "unauthorized", "log in first to authorize this app")

      {:error, :not_found} ->
        error(404, "invalid_client", "unknown client_id")

      {:error, :invalid_redirect_uri} ->
        error(400, "invalid_redirect_uri", "redirect_uri does not match registered URIs")

      {:error, :invalid_scope} ->
        error(400, "invalid_scope", "requested scope exceeds the app's allowed scopes")

      {:unavailable, why} ->
        unavailable(why)

      _ ->
        error(400, "invalid_request", "could not authorize")
    end
  end

  # ── POST /oauth/token ────────────────────────────────────────────────────

  def token(req) do
    body = decode_token_body(req)
    grant_type = body["grant_type"]

    case grant_type do
      "authorization_code" ->
        do_authorization_code(body)

      "refresh_token" ->
        do_refresh(body)

      "client_credentials" ->
        do_client_credentials(body)

      _ ->
        json(400, %{error: "unsupported_grant_type"})
    end
  end

  defp do_authorization_code(body) do
    case GatewayRpc.run(@gateway, :exchange_code_for_token, [body]) do
      {:ok, token_payload} ->
        json(200, present_token(token_payload))

      {:error, reason} ->
        json(400, %{error: oauth_error_for(reason)})

      {:unavailable, why} ->
        json(503, GatewayRpc.unavailable_body(why))
    end
  end

  defp do_refresh(body) do
    case GatewayRpc.run(@gateway, :refresh_token_grant, [body]) do
      {:ok, token_payload} ->
        json(200, present_token(token_payload))

      {:error, reason} ->
        json(400, %{error: oauth_error_for(reason)})

      {:unavailable, why} ->
        json(503, GatewayRpc.unavailable_body(why))
    end
  end

  defp do_client_credentials(body) do
    cid = body["client_id"]
    secret = body["client_secret"]
    scope = body["scope"]

    case GatewayRpc.run(@gateway, :client_credentials_grant, [cid, secret, scope]) do
      {:ok, token_payload} ->
        json(200, present_token(token_payload))

      {:error, reason} ->
        json(400, %{error: oauth_error_for(reason)})

      {:unavailable, why} ->
        json(503, GatewayRpc.unavailable_body(why))
    end
  end

  # ── POST /oauth/revoke ───────────────────────────────────────────────────

  def revoke(req) do
    body = decode_token_body(req)

    case GatewayRpc.run(@gateway, :revoke_token, [body]) do
      {:ok, :ok} ->
        json(200, %{})

      {:unavailable, why} ->
        json(503, GatewayRpc.unavailable_body(why))

      _ ->
        # RFC 7009 mandates idempotent success even on unknown token
        json(200, %{})
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp present_token(t) do
    %{
      access_token: t.access_token,
      token_type: t.token_type,
      scope: t.scope,
      created_at: t.created_at
    }
    |> maybe_put(:refresh_token, t[:refresh_token] || Map.get(t, :refresh_token))
    |> maybe_put(:expires_in, t[:expires_in] || Map.get(t, :expires_in))
  end

  defp maybe_put(m, _k, nil), do: m
  defp maybe_put(m, k, v), do: Map.put(m, k, v)

  defp oauth_error_for(:invalid_client), do: "invalid_client"
  defp oauth_error_for(:invalid_grant), do: "invalid_grant"
  defp oauth_error_for(:invalid_redirect_uri), do: "invalid_grant"
  defp oauth_error_for(:invalid_scope), do: "invalid_scope"
  defp oauth_error_for(_), do: "invalid_request"

  defp decode_token_body(req), do: decode_request_body(req)

  # PluginPlug が body_params を JSON 再エンコードして渡してくるので、
  # まず JSON で読む。空 body や、テストなどで直接 form 文字列が来た
  # 場合は URI.decode_query へフォールバック。
  defp decode_request_body(req) do
    raw = req[:body] || ""

    case JSON.decode(raw) do
      {:ok, %{} = m} -> m
      _ -> parse_form_body(raw)
    end
  end

  defp parse_form_body(""), do: %{}

  defp parse_form_body(body) when is_binary(body) do
    URI.decode_query(body)
  end

  defp parse_query(nil), do: %{}
  defp parse_query(""), do: %{}
  defp parse_query(q) when is_binary(q), do: URI.decode_query(q)

  # ブラウザは同名 cookie を二つ持ちうる ── 2026-09-05 以前の
  # `session_token` は host-only、以降は `Domain=.sukhi.f3liz.casa`。
  # 同名・同 path でも domain が違えばブラウザは別物として両方送るので、
  # 先頭だけ見ると古い方を拾って「セッション無し」になり、ログイン直後
  # なのに `/login` へ弾かれる(2026-09-22 実測)。ここでは全部の候補を
  # 返し、`resolve_all/2` に「生きているものを採用させる」。
  defp session_tokens_from_cookies(headers), do: cookie_values(headers, "session_token")

  # The `session_tokens` cookie's raw value, decoded via the gateway's own
  # `SessionCookie.decode_extra/1` — the format (base64url'd JSON) is that
  # module's to own, not something to re-parse by hand here.
  defp extra_tokens_from_cookies(headers) do
    case GatewayRpc.run(@session_cookie, :decode_extra, [cookie_value(headers, "session_tokens")]) do
      {:ok, tokens} -> tokens
      _ -> []
    end
  end

  defp cookie_value(headers, name), do: headers |> cookie_values(name) |> List.first()

  # 同名 cookie の値を、Cookie ヘッダの並び順で全部返す。名前が同じで
  # path/domain の違うものが複数あるとき、呼び元が候補を選べるように。
  defp cookie_values(headers, name) do
    headers
    |> Enum.filter(fn {k, _v} -> String.downcase(to_string(k)) == "cookie" end)
    |> Enum.flat_map(fn {_k, v} ->
      v
      |> to_string()
      |> String.split(";", trim: true)
      |> Enum.flat_map(fn pair ->
        case String.split(String.trim(pair), "=", parts: 2) do
          [^name, value] -> [value]
          _ -> []
        end
      end)
    end)
  end

  # All accounts this browser is signed into, resolved via the gateway's
  # `SessionCookie.resolve_all/2` — RPC failures degrade to "no session"
  # rather than surfacing a 503 here; `authorize_with_session`'s own RPC
  # calls right after would fail the same way and explain it properly.
  defp resolve_sessions(primary_token, extra_tokens) do
    case GatewayRpc.run(@session_cookie, :resolve_all, [primary_token, extra_tokens]) do
      {:ok, sessions} -> sessions
      _ -> []
    end
  end

  # Same flags as `SessionCookie`'s own cookie-writer — duplicated rather
  # than shared because `api` and the gateway are separate deployables
  # (RPC, not a shared compile-time dependency); see that module's
  # `put_primary_cookie/2` and `put_extra_cookie/2`.
  defp session_set_cookie_headers(primary_token, extra_tokens) do
    domain =
      case SukhiApi.Config.cookie_domain() do
        nil -> ""
        d -> "; Domain=#{d}"
      end

    flags = "SameSite=Lax; Secure; Max-Age=#{60 * 60 * 24 * 30}; Path=/#{domain}"
    cleared = "session_tokens=; HttpOnly; SameSite=Lax; Secure; Max-Age=0; Path=/#{domain}"
    primary = {"set-cookie", "session_token=#{primary_token}; HttpOnly; #{flags}"}
    # The SPA's (non-HttpOnly) sign of a session — see `SessionCookie`.
    mark = {"set-cookie", "sf_signed_in=1; #{flags}"}

    extra =
      case extra_tokens do
        [] ->
          {"set-cookie", cleared}

        tokens ->
          case GatewayRpc.run(@session_cookie, :encode_extra, [tokens]) do
            {:ok, value} -> {"set-cookie", "session_tokens=#{value}; HttpOnly; #{flags}"}
            _ -> {"set-cookie", cleared}
          end
      end

    [primary, mark, extra]
  end

  defp resolve_session(nil), do: {:error, :no_session}

  defp resolve_session(token) when is_binary(token) do
    case GatewayRpc.run(SukhiFedi.Accounts, :get_account_by_session_token, [token]) do
      {:ok, %{} = account} -> {:ok, account}
      {:ok, nil} -> {:error, :no_session}
      _ -> {:error, :no_session}
    end
  end

  # 同名 cookie の候補を順に見て、最初に生きていたセッションを採る。
  defp resolve_session_any([]), do: {:error, :no_session}

  defp resolve_session_any([token | rest]) do
    case resolve_session(token) do
      {:ok, account} -> {:ok, account}
      {:error, _} -> resolve_session_any(rest)
    end
  end

  # ── answers ──────────────────────────────────────────────────────────────

  defp decision(body, extra_headers \\ []) do
    {:ok,
     %{
       status: 200,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}] ++ extra_headers
     }}
  end

  defp redirect(base, params, extra_headers \\ []) do
    qs =
      params
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
      |> URI.encode_query()

    location = if qs == "", do: base, else: "#{base}?#{qs}"
    decision(%{decision: "redirect", location: location}, extra_headers)
  end

  defp error(status, code, detail) do
    json(status, %{error: code, error_description: detail})
  end

  defp unavailable(why), do: json(503, GatewayRpc.unavailable_body(why))

  defp json(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
