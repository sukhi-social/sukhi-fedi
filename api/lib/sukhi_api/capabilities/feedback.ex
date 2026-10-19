# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.Feedback do
  @moduledoc """
  The feedback inbox (docs/FEEDBACK.md). Transport only.

    * `POST /api/v1/feedback` — open; a bearer/cookie is optional and,
      when valid, only contributes the account id. Validation is the
      gateway changeset's, the rate limit is the gateway route's; this
      module just hands over the four known fields.
    * `GET /api/v1/admin/feedback`, `POST /api/v1/admin/feedback/:id/handled`
      — `admin:read` / `admin:write` plus `AdminAuth.require_admin/1`,
      like `Capabilities.Admin`.
  """

  use SukhiApi.Capability

  alias SukhiApi.{AdminAuth, GatewayRpc, OffsetPagination}
  alias SukhiApi.Views.{Feedback, Id}

  @fields ~w(body screen lang version)

  @impl true
  def routes do
    [
      {:post, "/api/v1/feedback", &create/1},
      {:get, "/api/v1/admin/feedback", &list/1, scope: "admin:read"},
      {:post, "/api/v1/admin/feedback/:id/handled", &handled/1, scope: "admin:write"}
    ]
  end

  def create(req) do
    account_id = viewer_id(req)
    attrs = req |> decode_body() |> Map.take(@fields)

    case GatewayRpc.run(SukhiFedi.Feedback, :submit, [attrs, account_id]) do
      {:ok, item} -> ok(202, %{id: Id.encode(item.id)})
      {:error, %{} = cs} -> ok(422, %{error: "validation_failed", details: cs_errors(cs)})
      {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
    end
  end

  def list(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req) do
      pagination = OffsetPagination.parse(req[:query])
      handled = req[:query] |> parse_query() |> Map.get("handled") |> parse_bool()

      case GatewayRpc.run(SukhiFedi.Feedback, :list, [pagination, handled]) do
        {:ok, {items, total}} ->
          ok(200, %{
            items: Feedback.render_list(items),
            pagination: OffsetPagination.meta(pagination, total)
          })

        {:unavailable, why} ->
          ok(503, GatewayRpc.unavailable_body(why))
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  def handled(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req) do
      case GatewayRpc.run(SukhiFedi.Feedback, :mark_handled, [req[:path_params]["id"], admin.id]) do
        {:ok, item} -> ok(200, Feedback.render(item))
        {:error, :not_found} -> ok(404, %{error: "feedback_not_found"})
        {:unavailable, why} -> ok(503, GatewayRpc.unavailable_body(why))
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # The router already verified whatever credential came; no account on
  # assigns means anonymous.
  defp viewer_id(%{assigns: %{current_account: %{id: id}}}) when is_integer(id), do: id
  defp viewer_id(_req), do: nil

  defp cs_errors(%{errors: errors}),
    do: Map.new(errors, fn {k, {msg, _}} -> {k, msg} end)

  defp cs_errors(_), do: %{}

  defp decode_body(req) do
    case JSON.decode(req[:body] || "") do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp parse_query(q) when is_binary(q) and q != "", do: URI.decode_query(q)
  defp parse_query(_), do: %{}

  defp parse_bool(v) when v in ["true", "1"], do: true
  defp parse_bool(v) when v in ["false", "0"], do: false
  defp parse_bool(_), do: nil

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
