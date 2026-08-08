# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Auth.EmailLoginController do
  @moduledoc """
  The email-code login door:

      POST /login/email/request   {email}        → always {ok: true}
      POST /login/email           {email, code}  → cookie or TOTP step

  `request` answers `{ok: true}` whether or not the address belongs to
  anyone — the mailbox knows, we don't tell (`EmailAuth` holds that
  rule). A proven code is a first factor like the password, so it runs
  through the same `finish_first_factor/2` and the same TOTP gate.
  """

  import Plug.Conn

  alias SukhiFedi.Auth.EmailAuth
  alias SukhiFedi.Web.Auth.{LoginController, MailIpGate}

  def request(conn) do
    if MailIpGate.ok?(conn) do
      do_request(conn)
    else
      json(conn, 429, %{error: "rate_limited"})
    end
  end

  defp do_request(conn) do
    email = to_string(conn.body_params["email"] || "")

    case EmailAuth.request_login_code(email) do
      :ok -> json(conn, 200, %{ok: true})
      {:error, :invalid_email} -> json(conn, 422, %{error: "email"})
      {:error, :rate_limited} -> json(conn, 429, %{error: "rate_limited"})
    end
  end

  def submit(conn) do
    email = to_string(conn.body_params["email"] || "")
    code = to_string(conn.body_params["code"] || "")

    case EmailAuth.confirm_login(email, code) do
      {:ok, account} ->
        LoginController.finish_first_factor(conn, account, conn.body_params["mode"] == "add")

      {:error, :expired} ->
        json(conn, 422, %{error: "expired"})

      {:error, :too_many_attempts} ->
        json(conn, 429, %{error: "too_many_attempts"})

      {:error, :invalid_code} ->
        json(conn, 422, %{error: "code"})
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(data))
  end
end
