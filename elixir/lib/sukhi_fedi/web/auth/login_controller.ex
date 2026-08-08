# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Auth.LoginController do
  @moduledoc """
  `POST /login` — validate username + password; `POST /login/totp` —
  the second step when the account has app-2FA turned on.

  The sign-in *form* lives in the SPA (`web/src/routes/login`); these
  are the JSON endpoints behind it. A first factor alone answers either
  `{ok: true}` with the `session_token` cookie set, or
  `{second_factor: "totp", pending: …}` with **no** cookie — the SPA
  then asks for the 6-digit code and finishes via `/login/totp`.

  `finish_first_factor/2` is shared with the email-code door
  (`EmailLoginController`), so "password proven" and "mailbox proven"
  lead through exactly the same 2FA gate. Passkey login bypasses it by
  design (`SukhiFedi.Auth.SecondFactor`).

  Separate door from `/admin/login` (which takes a pre-issued bearer).
  """

  import Plug.Conn

  alias SukhiFedi.Auth.SecondFactor
  alias SukhiFedi.LocalAccounts
  alias SukhiFedi.Web.Auth.SessionCookie

  # 10 TOTP guesses per account per 5 minutes — a 6-digit space is
  # only safe while guessing stays this slow.
  @totp_rate {10, 5 * 60 * 1000}

  def submit(conn) do
    username = to_string(conn.body_params["username"] || "")
    password = to_string(conn.body_params["password"] || "")

    case LocalAccounts.authenticate(username, password) do
      {:ok, account} ->
        finish_first_factor(conn, account, add?(conn))

      {:error, :invalid} ->
        json(conn, 401, %{error: "invalid"})
    end
  end

  def totp(conn) do
    pending = to_string(conn.body_params["pending"] || "")
    code = to_string(conn.body_params["code"] || "")

    with {:ok, account} <- SecondFactor.verify_pending(pending),
         :ok <- totp_rate_ok(account),
         :ok <- SecondFactor.verify_totp(account, code) do
      conn
      |> mint(account, add?(conn))
      |> json(200, %{ok: true})
    else
      {:error, :invalid_pending} -> json(conn, 401, %{error: "pending"})
      {:error, :rate_limited} -> json(conn, 429, %{error: "rate_limited"})
      {:error, :invalid_code} -> json(conn, 422, %{error: "code"})
    end
  end

  def logout(conn) do
    conn
    |> SessionCookie.drop()
    |> put_resp_header("location", "/")
    |> send_resp(302, "")
  end

  @doc """
  A first factor has been proven for `account`: mint the session, or
  hand back a pending token when the account wants a TOTP on top.

  `add?` is true for "sign in to *another* account" rather than a
  fresh login (`Web.Auth.SessionCookie.mint_additional/2`) — the SPA
  resends `mode: "add"` on the TOTP step too, since the pending token
  itself carries nothing but the account.
  """
  def finish_first_factor(conn, account, add? \\ false) do
    if SecondFactor.required?(account) do
      json(conn, 200, %{second_factor: "totp", pending: SecondFactor.issue_pending(account)})
    else
      conn
      |> mint(account, add?)
      |> json(200, %{ok: true})
    end
  end

  defp mint(conn, account, true), do: SessionCookie.mint_additional(conn, account)
  defp mint(conn, account, false), do: SessionCookie.mint(conn, account)

  defp add?(conn), do: conn.body_params["mode"] == "add"

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
