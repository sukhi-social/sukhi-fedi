# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Auth.SecurityController do
  @moduledoc """
  The signed-in security settings surface (`/settings/security` page in
  the SPA):

      GET  /auth/state                      what factors this account has
      POST /settings/reauth/request         → code mail to own verified address
      POST /settings/email/request          {email, password?|reauth_code?} → code mail
      POST /settings/email/confirm          {code} → email verified
      POST /settings/totp/setup             → {secret, otpauth}
      POST /settings/totp/enable            {code}
      POST /settings/totp/disable           {password?|reauth_code?}
      POST /settings/passkeys/options       → {ref, publicKey}
      POST /settings/passkeys               {ref, attestation…, nickname}
      POST /settings/passkeys/:id/delete    {password?|reauth_code?}
      GET  /settings/sessions               active sessions (current one marked)
      POST /settings/sessions/:id/revoke    {password?|reauth_code?}

  Mutations are **session-cookie only** (`SessionCookie` moduledoc has
  the why: bearers travel through third-party apps). `GET /auth/state`
  additionally accepts a read-scoped bearer so the SPA can decide
  whether to show the email nudge right after signup; the response's
  `manageable` flag tells it whether mutations would work or a
  re-login is needed first.

  Factor-*removing* changes (TOTP off, passkey delete) and replacing a
  verified email re-prove the owner; factor-*adding* ones don't. The
  proof is the password when the account has one, otherwise a fresh
  code mailed to the verified address (`reauth_request/1`) — the
  password is optional/legacy now, so the gate must stand without it.
  """

  import Plug.Conn

  alias SukhiFedi.Auth.{EmailAuth, Passkeys, SecondFactor}
  alias SukhiFedi.{LocalAccounts, OAuth}
  alias SukhiFedi.Schema.Account
  alias SukhiFedi.Web.Auth.SessionCookie
  alias SukhiFedi.Web.BearerToken

  # Shares the login bucket: guessing the enable code is the same
  # attack as guessing the login code.
  @totp_rate {10, 5 * 60 * 1000}

  # ── state ────────────────────────────────────────────────────────────────

  def state(conn) do
    case SessionCookie.account(conn) do
      %Account{} = account ->
        json(conn, 200, render_state(account, true))

      nil ->
        case bearer_account(conn) do
          %Account{} = account -> json(conn, 200, render_state(account, false))
          nil -> json(conn, 401, %{error: "unauthorized"})
        end
    end
  end

  defp render_state(account, manageable?) do
    %{
      manageable: manageable?,
      # 誰の分の state か(local アカウントなので acct はドメイン無しの
      # username そのまま)。マルチアカウントのブラウザだと、mutations
      # が従う session_token の持ち主と、SPA がいま bearer で見せている
      # アカウントがズレることがある ── SPA 側はこれを currentAccount()
      # の acct と突き合わせて、ズレていたら警告できる。
      acct: account.username,
      email: account.email,
      email_verified: not is_nil(account.email_verified_at),
      has_password: is_binary(account.password_hash),
      totp_enabled: not is_nil(account.totp_enabled_at),
      totp_pending: is_binary(account.totp_secret) and is_nil(account.totp_enabled_at),
      passkeys: Enum.map(Passkeys.list(account), &render_passkey/1)
    }
  end

  defp render_passkey(cred) do
    %{
      id: cred.id,
      nickname: cred.nickname,
      created_at: DateTime.to_iso8601(cred.created_at),
      last_used_at: cred.last_used_at && DateTime.to_iso8601(cred.last_used_at)
    }
  end

  # Read-only fallback for the freshly-signed-up SPA: a user-bound
  # bearer with read scope may *look*, never touch.
  defp bearer_account(conn) do
    with token when is_binary(token) <- BearerToken.extract(conn),
         {:ok, %{account: %Account{} = account, scopes: scopes}} <- OAuth.verify_bearer(token),
         true <- "read" in scopes or "read:accounts" in scopes do
      account
    else
      _ -> nil
    end
  end

  # ── reauth (the "prove it's still you" code) ─────────────────────────────

  def reauth_request(conn) do
    with_session(conn, fn account ->
      case EmailAuth.request_reauth(account) do
        :ok -> json(conn, 200, %{ok: true})
        {:error, :no_verified_email} -> json(conn, 409, %{error: "no_verified_email"})
        {:error, :rate_limited} -> json(conn, 429, %{error: "rate_limited"})
        {:error, :send_failed} -> json(conn, 502, %{error: "send_failed"})
      end
    end)
  end

  # ── email ────────────────────────────────────────────────────────────────

  def email_request(conn) do
    with_session(conn, fn account ->
      email = to_string(conn.body_params["email"] || "")

      with :ok <- maybe_reauth(conn, account),
           :ok <- EmailAuth.request_verification(account, email) do
        json(conn, 200, %{ok: true})
      else
        {:error, :reauth} -> json(conn, 403, %{error: "reauth"})
        {:error, :invalid_email} -> json(conn, 422, %{error: "email"})
        {:error, :email_taken} -> json(conn, 422, %{error: "email_taken"})
        {:error, :rate_limited} -> json(conn, 429, %{error: "rate_limited"})
        {:error, :send_failed} -> json(conn, 502, %{error: "send_failed"})
      end
    end)
  end

  def email_confirm(conn) do
    with_session(conn, fn account ->
      code = to_string(conn.body_params["code"] || "")

      case EmailAuth.confirm_verification(account, code) do
        {:ok, updated} -> json(conn, 200, %{ok: true, email: updated.email})
        {:error, :expired} -> json(conn, 422, %{error: "expired"})
        {:error, :too_many_attempts} -> json(conn, 429, %{error: "too_many_attempts"})
        {:error, :email_taken} -> json(conn, 422, %{error: "email_taken"})
        {:error, :invalid_code} -> json(conn, 422, %{error: "code"})
      end
    end)
  end

  # An account that already proved an address must re-prove the owner
  # to swap it — a hijacked session shouldn't be able to quietly point
  # email login somewhere else. First-time setup is free.
  defp maybe_reauth(conn, %Account{email_verified_at: %DateTime{}} = account),
    do: reauth_ok(conn, account)

  defp maybe_reauth(_conn, %Account{}), do: :ok

  # ── totp ─────────────────────────────────────────────────────────────────

  def totp_setup(conn) do
    with_session(conn, fn account ->
      case SecondFactor.setup_totp(account) do
        {:ok, payload} -> json(conn, 200, payload)
        {:error, :already_enabled} -> json(conn, 409, %{error: "already_enabled"})
      end
    end)
  end

  def totp_enable(conn) do
    with_session(conn, fn account ->
      code = to_string(conn.body_params["code"] || "")

      with :ok <- totp_rate_ok(account),
           {:ok, _} <- SecondFactor.enable_totp(account, code) do
        json(conn, 200, %{ok: true})
      else
        {:error, :rate_limited} -> json(conn, 429, %{error: "rate_limited"})
        {:error, :no_setup} -> json(conn, 409, %{error: "no_setup"})
        {:error, :invalid_code} -> json(conn, 422, %{error: "code"})
      end
    end)
  end

  def totp_disable(conn) do
    with_session(conn, fn account ->
      case reauth_ok(conn, account) do
        :ok ->
          {:ok, _} = SecondFactor.disable_totp(account)
          json(conn, 200, %{ok: true})

        {:error, :reauth} ->
          json(conn, 403, %{error: "reauth"})
      end
    end)
  end

  # ── sessions (where am I signed in) ──────────────────────────────────────

  def sessions(conn) do
    with_session(conn, fn account ->
      current = SessionCookie.current_token_hash(conn)

      list =
        account
        |> LocalAccounts.list_sessions()
        |> Enum.map(&render_session(&1, current))

      json(conn, 200, %{sessions: list})
    end)
  end

  defp render_session(session, current_hash) do
    %{
      id: session.id,
      ip: SukhiFedi.Auth.LoginNotice.coarse_ip(session.ip_text),
      user_agent: session.user_agent,
      created_at: DateTime.to_iso8601(session.created_at),
      last_seen_at: session.last_seen_at && DateTime.to_iso8601(session.last_seen_at),
      current: session.token_hash == current_hash
    }
  end

  # Signing a device out is owner-proof gated, same as removing a factor:
  # a hijacked session shouldn't be able to evict the real owner's
  # devices. The account's own current session is fair game to revoke too
  # — that's just "sign out here".
  def session_revoke(conn) do
    with_session(conn, fn account ->
      with :ok <- reauth_ok(conn, account),
           {id, ""} <- Integer.parse(to_string(conn.path_params["id"] || "")),
           :ok <- LocalAccounts.revoke_session(account, id) do
        json(conn, 200, %{ok: true})
      else
        {:error, :reauth} -> json(conn, 403, %{error: "reauth"})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        _ -> json(conn, 404, %{error: "not_found"})
      end
    end)
  end

  # ── passkeys ─────────────────────────────────────────────────────────────

  def passkey_options(conn) do
    with_session(conn, fn account ->
      {ref, options} = Passkeys.register_options(account)
      json(conn, 200, %{ref: ref, publicKey: options})
    end)
  end

  def passkey_register(conn) do
    with_session(conn, fn account ->
      case Passkeys.register_finish(account, conn.body_params) do
        {:ok, cred} -> json(conn, 200, %{ok: true, passkey: render_passkey(cred)})
        {:error, :already_registered} -> json(conn, 422, %{error: "already_registered"})
        {:error, :invalid_challenge} -> json(conn, 422, %{error: "challenge"})
        {:error, :verification_failed} -> json(conn, 422, %{error: "verification"})
      end
    end)
  end

  def passkey_delete(conn) do
    with_session(conn, fn account ->
      with :ok <- reauth_ok(conn, account),
           {id, ""} <- Integer.parse(to_string(conn.path_params["id"] || "")),
           :ok <- Passkeys.delete(account, id) do
        json(conn, 200, %{ok: true})
      else
        {:error, :reauth} -> json(conn, 403, %{error: "reauth"})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        _ -> json(conn, 404, %{error: "not_found"})
      end
    end)
  end

  # ── shared ───────────────────────────────────────────────────────────────

  defp with_session(conn, fun) do
    case SessionCookie.account(conn) do
      %Account{} = account -> fun.(account)
      nil -> json(conn, 401, %{error: "unauthorized"})
    end
  end

  # The single owner-re-proof rule: password when the account has one,
  # otherwise a fresh reauth code mailed to the verified address.
  defp reauth_ok(conn, %Account{password_hash: hash} = account) when is_binary(hash) do
    case LocalAccounts.check_password(account, to_string(conn.body_params["password"] || "")) do
      :ok -> :ok
      {:error, :invalid} -> {:error, :reauth}
    end
  end

  defp reauth_ok(conn, %Account{} = account) do
    case EmailAuth.confirm_reauth(account, to_string(conn.body_params["reauth_code"] || "")) do
      :ok -> :ok
      {:error, _} -> {:error, :reauth}
    end
  end

  defp totp_rate_ok(%{id: id}) do
    {limit, scale} = @totp_rate

    case Hammer.check_rate("totp:#{id}", scale, limit) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(data))
  end
end
