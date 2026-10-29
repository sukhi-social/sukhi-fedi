# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.AccountDeletionController do
  @moduledoc """
  Closing one's own account (`/settings/close` in the SPA):

      GET  /settings/close/status     → {pending: nil | {scheduled_for}}
      POST /settings/close/request    {password?|reauth_code?}
      POST /settings/close/cancel

  As easy as signing up: one re-proof (the same `SecurityController.reauth_ok/2`
  rule as every destructive owner action) and one press; no reason is asked.
  Cancelling needs only the session — being signed in *is* the proof, and a
  hijacker's request is exactly what the owner must be able to undo.
  Session-cookie only: a bearer travelling through a third-party app must not
  be able to close an account.
  """

  import Plug.Conn

  alias SukhiFedi.AccountDeletion
  alias SukhiFedi.Schema
  alias SukhiFedi.Schema.Account
  alias SukhiFedi.Web.Auth.{SecurityController, SessionCookie}

  def show(conn) do
    with_session(conn, fn account ->
      json(conn, 200, render(AccountDeletion.pending(account)))
    end)
  end

  def request(conn) do
    with_session(conn, fn account ->
      with :ok <- SecurityController.reauth_ok(conn, account),
           {:ok, d} <- AccountDeletion.request(account) do
        json(conn, 200, render(d))
      else
        {:error, :reauth} -> json(conn, 403, %{error: "reauth"})
        {:error, reason} -> json(conn, 422, %{error: to_string(reason)})
      end
    end)
  end

  def cancel(conn) do
    with_session(conn, fn account ->
      case AccountDeletion.cancel(account) do
        :ok -> json(conn, 200, render(nil))
        {:error, :none} -> json(conn, 200, render(nil))
        {:error, :started} -> json(conn, 409, %{error: "started"})
      end
    end)
  end

  defp render(nil), do: %{pending: nil}

  defp render(%Schema.AccountDeletion{scheduled_for: at}),
    do: %{pending: %{scheduled_for: DateTime.to_iso8601(at)}}

  defp with_session(conn, fun) do
    case SessionCookie.account(conn) do
      %Account{} = account -> fun.(account)
      nil -> json(conn, 401, %{error: "unauthorized"})
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(data))
  end
end
