# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.SelfCleanupController do
  @moduledoc """
  The signed-in self-cleanup surface (`/settings/cleanup` page in the SPA):

      POST /settings/cleanup/preview   {older_than_days?} → honest dry-run count
      POST /settings/cleanup/execute   {older_than_days?, password?|reauth_code?}

  *Archive locally, never hard-delete, federate the Delete* (see
  `SukhiFedi.SelfCleanup`). Preview is read-only and shows what *would* be
  archived and what's protected (pinned, DMs) **first**; execute is the
  owner-re-proof–gated commit, never a background toggle. Session-cookie only,
  same surface and `reauth_ok/2` rule as `SecurityController` (a bearer
  travelling through a third-party app must not be able to wipe a history).
  """

  import Plug.Conn

  alias SukhiFedi.Schema.Account
  alias SukhiFedi.SelfCleanup
  alias SukhiFedi.Web.Auth.{SecurityController, SessionCookie}

  # A history cleanup is heavy and self-targeted; one burst is plenty.
  @execute_rate {3, 60 * 60 * 1000}

  def preview(conn) do
    with_session(conn, fn account ->
      days = older_than_days(conn)
      result = SelfCleanup.run(account.id, :dry_run, older_than_days: days)
      json(conn, 200, render(result))
    end)
  end

  def execute(conn) do
    with_session(conn, fn account ->
      days = older_than_days(conn)

      with :ok <- SecurityController.reauth_ok(conn, account),
           :ok <- execute_rate_ok(account) do
        result =
          SelfCleanup.run(account.id, :execute,
            older_than_days: days,
            reason: "self_cleanup"
          )

        json(conn, 200, render(result))
      else
        {:error, :reauth} -> json(conn, 403, %{error: "reauth"})
        {:error, :rate_limited} -> json(conn, 429, %{error: "rate_limited"})
      end
    end)
  end

  # ── shared ───────────────────────────────────────────────────────────────

  # `older_than_days` is the only knob: a non-negative integer, else 0 (= all).
  defp older_than_days(conn) do
    case conn.body_params["older_than_days"] do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp render(%{affected: affected, protected: %{pinned: pinned, direct: direct}} = result) do
    %{
      mode: result.mode,
      older_than_days: result.older_than_days,
      affected: affected,
      protected: %{pinned: pinned, direct: direct}
    }
  end

  defp with_session(conn, fun) do
    case SessionCookie.account(conn) do
      %Account{} = account -> fun.(account)
      nil -> json(conn, 401, %{error: "unauthorized"})
    end
  end

  defp execute_rate_ok(%{id: id}) do
    {limit, scale} = @execute_rate

    case Hammer.check_rate("self_cleanup:#{id}", scale, limit) do
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
