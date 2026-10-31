# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Auth.SignupEmailController do
  @moduledoc """
  The mailbox round-trip *before* an account exists:

      POST /signup/email/request   {email}         → code mail
      POST /signup/email/confirm   {email, code}   → {email_proof}
      POST /signup/session         {email_proof}   → session cookie

  The proof is a signed 20-minute token the signup form then carries
  into `POST /api/v1/accounts` — accounts are born with a verified
  address, which is what lets the password be optional. Right after the
  account exists, `session` mints a first-party session from that same
  proof, so email signup stands where a password login does: the new
  account can manage its security (passkeys, 2FA) at once instead of
  being bounced to a second login. Unlike the login door, `request`
  here *does* say `email_taken` out loud: the form needs to tell people
  to pick another address, and "taken" only reveals verified owners
  (who chose to be reachable there).
  """

  import Plug.Conn

  alias SukhiFedi.Auth.EmailAuth
  alias SukhiFedi.Schema.Account
  alias SukhiFedi.Web.Auth.{MailIpGate, SessionCookie}

  def request(conn) do
    if MailIpGate.ok?(conn) do
      do_request(conn)
    else
      json(conn, 429, %{error: "rate_limited"})
    end
  end

  defp do_request(conn) do
    email = to_string(conn.body_params["email"] || "")

    case EmailAuth.request_signup_code(email, lang_param(conn)) do
      :ok -> json(conn, 200, %{ok: true})
      {:error, :invalid_email} -> json(conn, 422, %{error: "email"})
      {:error, :email_taken} -> json(conn, 422, %{error: "email_taken"})
      {:error, :rate_limited} -> json(conn, 429, %{error: "rate_limited"})
      {:error, :send_failed} -> json(conn, 502, %{error: "send_failed"})
    end
  end

  def confirm(conn) do
    email = to_string(conn.body_params["email"] || "")
    code = to_string(conn.body_params["code"] || "")

    case EmailAuth.confirm_signup_code(email, code) do
      {:ok, proof} -> json(conn, 200, %{ok: true, email_proof: proof})
      {:error, :expired} -> json(conn, 422, %{error: "expired"})
      {:error, :too_many_attempts} -> json(conn, 429, %{error: "too_many_attempts"})
      {:error, :invalid_code} -> json(conn, 422, %{error: "code"})
    end
  end

  @doc """
  Mint a first-party session for the just-signed-up account, proving the
  mailbox with the same `email_proof` the signup carried. Lets email
  signup match a password login: the new account holds a `session_token`
  cookie immediately, so the cookie-only management surface (passkeys,
  2FA, email change) is reachable without a second trip through the login
  door. A passwordless account has no password to re-enter — the proven
  mailbox is the credential, exactly as it was at signup.
  """
  def session(conn) do
    proof = to_string(conn.body_params["email_proof"] || "")

    with {:ok, email} <- EmailAuth.verify_signup_proof(proof),
         %Account{} = account <- EmailAuth.login_account_by_email(email) do
      conn
      |> SessionCookie.mint(account)
      |> json(200, %{ok: true})
    else
      {:error, :invalid_proof} -> json(conn, 422, %{error: "email_proof_invalid"})
      nil -> json(conn, 404, %{error: "no_account"})
    end
  end

  # Optional "ja" / "ko": the language picked on the page, so the mail
  # reads in it. Missing or unknown → the bilingual mail.
  defp lang_param(conn) do
    case conn.body_params["lang"] do
      l when l in ["ja", "ko"] -> l
      _ -> nil
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(data))
  end
end
