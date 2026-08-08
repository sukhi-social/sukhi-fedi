# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Auth.PasskeyLoginController do
  @moduledoc """
  Passwordless login with a registered passkey:

      POST /login/passkey/options  {}          → {ref, publicKey}
      POST /login/passkey          {ref, …}    → cookie

  The browser turns `publicKey` into `navigator.credentials.get()`;
  the assertion comes back with the `ref` so the one-shot challenge
  row can be claimed. No TOTP step on top — the authenticator's own
  user verification (PIN / biometric) already is the second factor.

  Every failure is the same `401 {error: "passkey"}` on purpose:
  which part broke (unknown key, stale counter, bad signature) is for
  the logs, not for whoever is poking the endpoint.
  """

  import Plug.Conn

  alias SukhiFedi.Auth.Passkeys
  alias SukhiFedi.Web.Auth.SessionCookie

  def options(conn) do
    {ref, options} = Passkeys.login_options()
    json(conn, 200, %{ref: ref, publicKey: options})
  end

  def submit(conn) do
    case Passkeys.login_finish(conn.body_params) do
      {:ok, account} ->
        conn
        |> mint(account, conn.body_params["mode"] == "add")
        |> json(200, %{ok: true})

      {:error, _reason} ->
        json(conn, 401, %{error: "passkey"})
    end
  end

  # `mode: "add"` signs in to another account alongside whatever's
  # already primary, rather than replacing it — same convention as
  # LoginController's password/email doors.
  defp mint(conn, account, true), do: SessionCookie.mint_additional(conn, account)
  defp mint(conn, account, false), do: SessionCookie.mint(conn, account)

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(data))
  end
end
