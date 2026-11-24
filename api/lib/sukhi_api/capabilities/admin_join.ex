# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.AdminJoin do
  @moduledoc """
  The greeter's side of asking to join (docs/JOIN.md, step 2). Transport
  only: what may be said, the mail, the audit row and the erasing are
  `SukhiFedi.JoinApplications`'.

    * `GET  /api/admin/join_applications`                    — who is waiting, and the next day it is looked at
    * `GET  /api/admin/join_applications/:receipt`           — one, in full, with the address to write to
    * `POST /api/admin/join_applications/:receipt/welcome`   — `{note}`: the entry link goes out
    * `POST /api/admin/join_applications/:receipt/decline`   — `{reason}`: the gentle answer goes out

  Every route needs an `admin:read` / `admin:write` token (the router) and
  an admin account (`AdminAuth`, per handler), like the rest of
  `/api/admin/*`. The receipt number is the handle: it is what the person
  was given and what the greeter reads aloud.
  """

  use SukhiApi.Capability

  alias SukhiApi.{AdminAuth, GatewayRpc}
  alias SukhiApi.Views.AdminJoin

  # A mail goes out inside the answering calls.
  @mail_timeout 20_000

  @impl true
  def routes do
    [
      {:get, "/api/admin/join_applications", &list/1, scope: "admin:read"},
      {:get, "/api/admin/join_applications/:receipt", &show/1, scope: "admin:read"},
      {:post, "/api/admin/join_applications/:receipt/welcome", &welcome/1, scope: "admin:write"},
      {:post, "/api/admin/join_applications/:receipt/decline", &decline/1, scope: "admin:write"}
    ]
  end

  def list(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req),
         {:ok, apps} <- GatewayRpc.run(SukhiFedi.JoinApplications, :list_waiting, []),
         {:ok, info} <- GatewayRpc.run(SukhiFedi.JoinApplications, :info, []) do
      ok(200, AdminJoin.render_list(apps, info))
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
      _ -> ok(500, %{error: "internal_error"})
    end
  end

  def show(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req),
         {:ok, app} <-
           GatewayRpc.run(SukhiFedi.JoinApplications, :fetch_waiting, [receipt(req)]) do
      ok(200, AdminJoin.render(app))
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      other -> failure(other)
    end
  end

  def welcome(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req),
         {:ok, app} <-
           GatewayRpc.run(
             SukhiFedi.JoinApplications,
             :welcome,
             [receipt(req), text(req, "note"), admin.id],
             @mail_timeout
           ) do
      ok(200, %{receipt: app.receipt, state: "welcomed", entry_valid_days: 14})
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      other -> failure(other)
    end
  end

  def decline(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req),
         {:ok, :ok} <-
           GatewayRpc.run(
             SukhiFedi.JoinApplications,
             :decline,
             [receipt(req), text(req, "reason"), admin.id],
             @mail_timeout
           ) do
      ok(200, %{receipt: receipt(req), state: "declined"})
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      other -> failure(other)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Every domain "no" in one place; the same words `Capabilities.Join` uses.
  defp failure({:error, :not_found}), do: ok(404, %{error: "join_not_found"})
  defp failure({:error, :send_failed}), do: ok(502, %{error: "send_failed"})

  defp failure({:error, :too_long}),
    do: ok(422, %{error: "validation_failed", details: %{text: "too_long"}})

  defp failure({:unavailable, why}), do: ok(503, GatewayRpc.unavailable_body(why))
  defp failure(_), do: ok(500, %{error: "internal_error"})

  defp receipt(req), do: to_string(req[:path_params]["receipt"] || "")

  defp text(req, field) do
    case JSON.decode(req[:body] || "") do
      {:ok, %{^field => v}} when is_binary(v) -> v
      _ -> nil
    end
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
