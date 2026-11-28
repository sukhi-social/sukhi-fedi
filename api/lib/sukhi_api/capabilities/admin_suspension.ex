# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.AdminSuspension do
  @moduledoc """
  The admin's side of the rests other servers ask of us (FEP-f799,
  docs/DELIVERY_SUSPENSION.md, step 6). Transport only: what is held, what
  is safe to show and the audit row are `SukhiFedi.Fedi.DeliverySuspension.Admin`'s.

    * `GET  /api/admin/delivery_suspensions`          — every notice we hold: controller, target, revision, end, when it was last checked, ignored or not
    * `POST /api/admin/delivery_suspensions/ignore`   — `{id}`: do not hold deliveries for this one, here (the peer's record is not changed)
    * `POST /api/admin/delivery_suspensions/unignore` — `{id}`: hold them again, for as long as it still runs

  The notice's `id` is a URL, so it travels in the body, not the path. Every
  route needs an `admin:read` / `admin:write` token (the router) and an admin
  account (`AdminAuth`, per handler).
  """

  use SukhiApi.Capability

  alias SukhiApi.{AdminAuth, GatewayRpc}
  alias SukhiApi.Views.AdminSuspension, as: View

  @admin SukhiFedi.Fedi.DeliverySuspension.Admin

  @impl true
  def routes do
    [
      {:get, "/api/admin/delivery_suspensions", &list/1, scope: "admin:read"},
      {:post, "/api/admin/delivery_suspensions/ignore", &ignore/1, scope: "admin:write"},
      {:post, "/api/admin/delivery_suspensions/unignore", &unignore/1, scope: "admin:write"}
    ]
  end

  def list(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req),
         {:ok, rows} <- GatewayRpc.run(@admin, :list, []) do
      ok(200, View.render_list(rows))
    else
      other -> failure(other)
    end
  end

  def ignore(req), do: choose(req, :ignore)
  def unignore(req), do: choose(req, :unignore)

  defp choose(req, fun) do
    with {:ok, admin} <- AdminAuth.require_admin(req),
         {:ok, id} <- notice_id(req),
         {:ok, :ok} <- GatewayRpc.run(@admin, fun, [id, admin.id]) do
      ok(200, %{id: id, ignored: fun == :ignore})
    else
      other -> failure(other)
    end
  end

  defp failure({:error, :forbidden}), do: ok(403, %{error: "admin_required"})
  defp failure({:error, :not_found}), do: ok(404, %{error: "suspension_not_found"})
  defp failure({:error, :bad_request}), do: ok(400, %{error: "bad_request"})
  defp failure({:unavailable, why}), do: ok(503, GatewayRpc.unavailable_body(why))
  defp failure(_), do: ok(500, %{error: "internal_error"})

  defp notice_id(req) do
    case JSON.decode(req[:body] || "") do
      {:ok, %{"id" => id}} when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :bad_request}
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
