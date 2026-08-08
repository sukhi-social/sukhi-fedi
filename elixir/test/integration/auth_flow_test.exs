# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.AuthFlowTest do
  @moduledoc """
  The login doors over HTTP, through the real router pipeline:
  password (+ TOTP step), email code, passkey options, and the
  cookie-gated security settings surface.
  """

  use SukhiFedi.IntegrationCase, async: false

  import Plug.Conn
  import Plug.Test

  @moduletag :integration

  alias SukhiFedi.Auth.TOTP
  alias SukhiFedi.{LocalAccounts, Mailer}
  alias SukhiFedi.Web.Router

  @opts Router.init([])

  setup do
    Mailer.Capture.clear()

    n = System.unique_integer([:positive])
    password = "long-enough-pass"
    {:ok, account} = LocalAccounts.create_admin("flow_#{n}", password)

    %{account: account, username: "flow_#{n}", password: password, email: "flow_#{n}@example.test"}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp post_json(path, body, cookie \\ nil) do
    conn = conn(:post, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json")
    conn = if cookie, do: put_req_header(conn, "cookie", "session_token=#{cookie}"), else: conn
    Router.call(conn, @opts)
  end

  defp get_json(path, headers) do
    conn =
      Enum.reduce(headers, conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end)

    Router.call(conn, @opts)
  end

  defp body!(conn), do: JSON.decode!(conn.resp_body)

  defp session_cookie!(conn) do
    [setcookie] = Plug.Conn.get_resp_header(conn, "set-cookie")
    [_, token] = Regex.run(~r/session_token=([^;]+)/, setcookie)
    token
  end

  defp login!(username, password) do
    conn = post_json("/login", %{username: username, password: password})
    assert conn.status == 200
    assert %{"ok" => true} = body!(conn)
    session_cookie!(conn)
  end

  defp verify_email!(cookie, email) do
    conn = post_json("/settings/email/request", %{email: email}, cookie)
    assert conn.status == 200

    %{body: mail_body} = Mailer.Capture.last_to(email)
    [_, code] = Regex.run(~r/\n\s+(\d{6})\n/, mail_body)

    conn = post_json("/settings/email/confirm", %{code: code}, cookie)
    assert conn.status == 200
    code
  end

  # ── password door ──────────────────────────────────────────────────────

  test "password login mints the cookie", %{username: u, password: p} do
    assert is_binary(login!(u, p))
  end

  test "a wrong password is a 401", %{username: u} do
    conn = post_json("/login", %{username: u, password: "wrong-pass-here"})
    assert conn.status == 401
  end

  # ── TOTP second factor ─────────────────────────────────────────────────

  test "with app-2FA on, login becomes two steps", %{
    account: account,
    username: u,
    password: p
  } do
    # set up + enable TOTP (settings surface, cookie-gated)
    cookie = login!(u, p)

    conn = post_json("/settings/totp/setup", %{}, cookie)
    assert conn.status == 200
    %{"secret" => secret_b32, "otpauth" => "otpauth://totp/" <> _} = body!(conn)
    secret = Base.decode32!(secret_b32, padding: false)

    enable_code = TOTP.code(secret, current_step())
    conn = post_json("/settings/totp/enable", %{code: enable_code}, cookie)
    assert conn.status == 200

    # first factor alone now yields a pending token, no cookie
    conn = post_json("/login", %{username: u, password: p})
    assert conn.status == 200
    assert %{"second_factor" => "totp", "pending" => pending} = body!(conn)
    assert Plug.Conn.get_resp_header(conn, "set-cookie") == []

    # the enable burned the current step; the next step is within drift
    conn = post_json("/login/totp", %{pending: pending, code: TOTP.code(secret, current_step() + 1)})
    assert conn.status == 200
    assert %{"ok" => true} = body!(conn)
    assert is_binary(session_cookie!(conn))

    # ...and that code is burned too (replay refused)
    conn = post_json("/login", %{username: u, password: p})
    %{"pending" => pending2} = body!(conn)
    conn = post_json("/login/totp", %{pending: pending2, code: TOTP.code(secret, current_step() + 1)})
    assert conn.status == 422

    # disabling needs the password and turns login back into one step
    cookie = account_cookie_after_2fa(account, u, p, secret)
    conn = post_json("/settings/totp/disable", %{password: "nope"}, cookie)
    assert conn.status == 403
    conn = post_json("/settings/totp/disable", %{password: p}, cookie)
    assert conn.status == 200

    assert is_binary(login!(u, p))
  end

  test "a garbage pending token is a 401" do
    conn = post_json("/login/totp", %{pending: "garbage", code: "000000"})
    assert conn.status == 401
  end

  # The window test above used up steps N and N+1; rather than wait 30
  # real seconds for a fresh one, rewind the replay high-water mark —
  # "time passed" as one UPDATE.
  defp account_cookie_after_2fa(account, u, p, secret) do
    import Ecto.Query

    {1, _} =
      from(a in SukhiFedi.Schema.Account, where: a.id == ^account.id)
      |> Repo.update_all(set: [totp_last_used_step: current_step() - 5])

    conn = post_json("/login", %{username: u, password: p})
    %{"pending" => pending} = body!(conn)
    conn = post_json("/login/totp", %{pending: pending, code: TOTP.code(secret, current_step())})
    assert conn.status == 200
    session_cookie!(conn)
  end

  defp current_step, do: div(System.os_time(:second), 30)

  # ── email door ─────────────────────────────────────────────────────────

  test "email request + confirm, then email login", %{username: u, password: p, email: email} do
    cookie = login!(u, p)
    verify_email!(cookie, email)

    # state reflects it — acct names whose settings this is (multi-account:
    # the SPA compares this against the bearer-active account to catch a
    # stale session_token cookie).
    conn = get_json("/auth/state", [{"cookie", "session_token=#{cookie}"}])
    assert %{"acct" => ^u, "email" => ^email, "email_verified" => true, "manageable" => true} = body!(conn)

    # now the email door works
    conn = post_json("/login/email/request", %{email: email})
    assert conn.status == 200

    %{body: mail_body} = Mailer.Capture.last_to(email)
    [_, code] = Regex.run(~r/\n\s+(\d{6})\n/, mail_body)

    conn = post_json("/login/email", %{email: email, code: code})
    assert conn.status == 200
    assert %{"ok" => true} = body!(conn)
    assert is_binary(session_cookie!(conn))
  end

  test "an unknown address gets ok and no mail" do
    ghost = "ghost_#{System.unique_integer([:positive])}@example.test"
    conn = post_json("/login/email/request", %{email: ghost})
    assert conn.status == 200
    assert %{"ok" => true} = body!(conn)
    assert is_nil(Mailer.Capture.last_to(ghost))
  end

  # ── passkey door (HTTP surface; crypto covered in passkeys_test) ──────

  test "passkey options come with a ref and a challenge" do
    conn = post_json("/login/passkey/options", %{})
    assert conn.status == 200
    assert %{"ref" => ref, "publicKey" => %{"challenge" => challenge}} = body!(conn)
    assert is_binary(ref) and is_binary(challenge)
  end

  test "a garbage passkey assertion is a 401" do
    conn = post_json("/login/passkey/options", %{})
    %{"ref" => ref} = body!(conn)

    conn =
      post_json("/login/passkey", %{
        ref: ref,
        credential_id: "AAAA",
        authenticator_data: "AAAA",
        signature: "AAAA",
        client_data_json: "AAAA"
      })

    assert conn.status == 401
  end

  # ── management gate ────────────────────────────────────────────────────

  test "settings mutations without a cookie are 401, state takes a bearer", %{
    account: account,
    username: u,
    password: p
  } do
    for path <- [
          "/settings/email/request",
          "/settings/totp/setup",
          "/settings/passkeys/options",
          "/settings/passkeys/1/delete"
        ] do
      conn = post_json(path, %{})
      assert conn.status == 401, "#{path} should require the session cookie"
    end

    # a user-bound bearer can read state (manageable: false) but not mutate
    {:ok, %{app: app}} = SukhiFedi.OAuth.register_app(%{name: "t", redirect_uris: "urn:ietf:wg:oauth:2.0:oob", scopes: "read write"})
    {:ok, %{access_token: token}} = SukhiFedi.OAuth.issue_initial_token(app.id, account.id, "read")

    conn = get_json("/auth/state", [{"authorization", "Bearer #{token}"}])
    assert conn.status == 200
    assert %{"manageable" => false} = body!(conn)

    _ = {u, p}
  end

  # ── the passwordless era ───────────────────────────────────────────────

  defp create_passwordless!(email) do
    conn = post_json("/signup/email/request", %{email: email})
    assert conn.status == 200
    %{body: mail} = Mailer.Capture.last_to(email)
    [_, code] = Regex.run(~r/\n\s+(\d{6})\n/, mail)

    conn = post_json("/signup/email/confirm", %{email: email, code: code})
    assert conn.status == 200
    %{"email_proof" => proof} = body!(conn)

    {:ok, issuer} =
      LocalAccounts.create_admin("flowinv_#{System.unique_integer([:positive])}", "long-enough-pass")

    {:ok, invite} = SukhiFedi.InviteCodes.issue(issuer.id)

    {:ok, account} =
      LocalAccounts.create(%{
        "username" => "pwless_#{System.unique_integer([:positive])}",
        "email_proof" => proof,
        "invite_code" => invite.code
      })

    account
  end

  defp email_login_cookie!(email) do
    conn = post_json("/login/email/request", %{email: email})
    assert conn.status == 200
    %{body: mail} = Mailer.Capture.last_to(email)
    [_, code] = Regex.run(~r/\n\s+(\d{6})\n/, mail)

    conn = post_json("/login/email", %{email: email, code: code})
    assert conn.status == 200
    session_cookie!(conn)
  end

  test "signup proof → passwordless account → email login → reauth-gated 2FA off" do
    email = "pwless_#{System.unique_integer([:positive])}@example.test"
    account = create_passwordless!(email)
    assert is_nil(account.password_hash)

    cookie = email_login_cookie!(email)

    conn = get_json("/auth/state", [{"cookie", "session_token=#{cookie}"}])
    assert %{"has_password" => false, "email_verified" => true} = body!(conn)

    # adding a factor needs no reauth
    conn = post_json("/settings/totp/setup", %{}, cookie)
    assert conn.status == 200
    %{"secret" => secret_b32} = body!(conn)
    secret = Base.decode32!(secret_b32, padding: false)

    conn = post_json("/settings/totp/enable", %{code: TOTP.code(secret, current_step())}, cookie)
    assert conn.status == 200

    # removing one without proof is refused
    conn = post_json("/settings/totp/disable", %{}, cookie)
    assert conn.status == 403
    assert %{"error" => "reauth"} = body!(conn)

    # ...but a fresh code to the verified address opens the gate
    conn = post_json("/settings/reauth/request", %{}, cookie)
    assert conn.status == 200
    %{body: mail} = Mailer.Capture.last_to(email)
    [_, reauth_code] = Regex.run(~r/\n\s+(\d{6})\n/, mail)

    conn = post_json("/settings/totp/disable", %{reauth_code: reauth_code}, cookie)
    assert conn.status == 200
  end

  test "signup/session mints a first-party session from the proof (email signup = password login)" do
    email = "pwsess_#{System.unique_integer([:positive])}@example.test"

    conn = post_json("/signup/email/request", %{email: email})
    assert conn.status == 200
    %{body: mail} = Mailer.Capture.last_to(email)
    [_, code] = Regex.run(~r/\n\s+(\d{6})\n/, mail)

    conn = post_json("/signup/email/confirm", %{email: email, code: code})
    %{"email_proof" => proof} = body!(conn)

    {:ok, issuer} =
      LocalAccounts.create_admin("flowinv_#{System.unique_integer([:positive])}", "long-enough-pass")

    {:ok, invite} = SukhiFedi.InviteCodes.issue(issuer.id)

    {:ok, _account} =
      LocalAccounts.create(%{
        "username" => "pwsess_#{System.unique_integer([:positive])}",
        "email_proof" => proof,
        "invite_code" => invite.code
      })

    # The same proof now trades for a session cookie — no second login.
    conn = post_json("/signup/session", %{email_proof: proof})
    assert conn.status == 200
    cookie = session_cookie!(conn)

    # And that cookie reaches the cookie-only management surface: setting up a
    # factor (the passkey/2FA screen) works straight away.
    conn = get_json("/auth/state", [{"cookie", "session_token=#{cookie}"}])
    assert %{"email_verified" => true} = body!(conn)

    conn = post_json("/settings/totp/setup", %{}, cookie)
    assert conn.status == 200
  end

  test "signup/session refuses a bad proof" do
    conn = post_json("/signup/session", %{email_proof: "not-a-real-proof"})
    assert conn.status == 422
    assert %{"error" => "email_proof_invalid"} = body!(conn)
  end

  test "password lifecycle: set without current, use, remove, email door stays" do
    email = "pwlife_#{System.unique_integer([:positive])}@example.test"
    account = create_passwordless!(email)
    cookie = email_login_cookie!(email)

    # first password asks for no current one
    conn =
      post_json(
        "/settings/password",
        %{new_password: "first-password", confirm_password: "first-password"},
        cookie
      )

    assert conn.status == 200
    assert %{"initial" => true} = body!(conn)

    # the legacy door now opens too
    assert is_binary(login!(account.username, "first-password"))

    # retiring it requires the password itself
    conn = post_json("/settings/password/remove", %{password: "wrong-password"}, cookie)
    assert conn.status == 403
    conn = post_json("/settings/password/remove", %{password: "first-password"}, cookie)
    assert conn.status == 200

    conn = post_json("/login", %{username: account.username, password: "first-password"})
    assert conn.status == 401

    conn = get_json("/auth/state", [{"cookie", "session_token=#{cookie}"}])
    assert %{"has_password" => false, "email_verified" => true} = body!(conn)
  end
end
