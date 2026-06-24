# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.Admin do
  @moduledoc """
  Admin dashboard API — custom `/api/admin/*` surface, not
  Mastodon-compatible. Every route requires:

    1. a valid OAuth bearer token with `admin:read` or `admin:write`
       scope (enforced by `SukhiApi.Router`), and
    2. `current_account.is_admin == true` (enforced per-handler via
       `SukhiApi.AdminAuth.require_admin/1`).

  Data operations live on the gateway's `SukhiFedi.Addons.Moderation`
  and `SukhiFedi.Accounts` contexts; admin mutations emit
  `sns.outbox.admin.*` outbox events that double as the audit trail.
  """

  use SukhiApi.Capability, addon: :moderation

  alias SukhiApi.{AdminAuth, GatewayRpc, OffsetPagination}
  alias SukhiApi.Views.{AdminAccount, AdminDomainBlock, AdminReport, MastodonAnnouncement}

  @impl true
  def routes do
    [
      # accounts
      {:get, "/api/admin/accounts", &list_accounts/1, scope: "admin:read"},
      {:get, "/api/admin/accounts/:id", &show_account/1, scope: "admin:read"},
      {:post, "/api/admin/accounts/:id/suspend", &suspend_account/1, scope: "admin:write"},
      {:post, "/api/admin/accounts/:id/unsuspend", &unsuspend_account/1, scope: "admin:write"},
      {:post, "/api/admin/accounts/:id/promote", &promote_account/1, scope: "admin:write"},
      {:post, "/api/admin/accounts/:id/demote", &demote_account/1, scope: "admin:write"},

      # reports
      {:get, "/api/admin/reports", &list_reports/1, scope: "admin:read"},
      {:get, "/api/admin/reports/:id", &show_report/1, scope: "admin:read"},
      {:post, "/api/admin/reports/:id/resolve", &resolve_report/1, scope: "admin:write"},

      # domain blocks
      {:get, "/api/admin/domain_blocks", &list_domain_blocks/1, scope: "admin:read"},
      {:post, "/api/admin/domain_blocks", &create_domain_block/1, scope: "admin:write"},
      {:delete, "/api/admin/domain_blocks", &delete_domain_block/1, scope: "admin:write"},

      # announcements
      {:get, "/api/admin/announcements", &list_announcements/1, scope: "admin:read"},
      {:post, "/api/admin/announcements", &create_announcement/1, scope: "admin:write"},
      {:put, "/api/admin/announcements/:id", &update_announcement/1, scope: "admin:write"},
      {:delete, "/api/admin/announcements/:id", &delete_announcement/1, scope: "admin:write"},

      # dashboard
      {:get, "/api/admin/stats", &stats/1, scope: "admin:read"}
    ]
  end

  # ── accounts ─────────────────────────────────────────────────────────────

  def list_accounts(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req) do
      q = parse_query(req[:query])
      filter = account_filter(q)
      pagination = OffsetPagination.parse(req[:query])

      case GatewayRpc.call(SukhiFedi.Accounts, :list_accounts, [filter, pagination]) do
        {:ok, {:ok, {accounts, total}}} ->
          page(AdminAccount.render_list(accounts), pagination, total)

        other ->
          rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  defp account_filter(q) do
    %{}
    |> maybe_put(:suspended, parse_bool(q["suspended"]))
    |> maybe_put(:is_admin, parse_bool(q["is_admin"]))
    |> maybe_put(:username, sanitized_prefix(q["username"]))
  end

  def show_account(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req),
         {:ok, id} <- parse_int(req[:path_params]["id"]) do
      case GatewayRpc.call(SukhiFedi.Accounts, :get_account, [id]) do
        {:ok, {:ok, account}} -> ok(200, AdminAccount.render(account))
        {:ok, {:error, :not_found}} -> ok(404, %{error: "account_not_found"})
        other -> rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
    end
  end

  def suspend_account(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req),
         {:ok, id} <- parse_int(req[:path_params]["id"]) do
      body = decode_body(req)
      reason = Map.get(body, "reason")

      case GatewayRpc.call(SukhiFedi.Addons.Moderation, :suspend_account, [id, admin.id, reason]) do
        {:ok, {:ok, account}} -> ok(200, AdminAccount.render(account))
        {:ok, {:error, :not_found}} -> ok(404, %{error: "account_not_found"})
        other -> rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
    end
  end

  def unsuspend_account(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req),
         {:ok, id} <- parse_int(req[:path_params]["id"]) do
      case GatewayRpc.call(SukhiFedi.Addons.Moderation, :unsuspend_account, [id, admin.id]) do
        {:ok, {:ok, account}} -> ok(200, AdminAccount.render(account))
        {:ok, {:error, :not_found}} -> ok(404, %{error: "account_not_found"})
        other -> rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
    end
  end

  def promote_account(req), do: set_admin_flag(req, true)
  def demote_account(req), do: set_admin_flag(req, false)

  defp set_admin_flag(req, flag) do
    with {:ok, admin} <- AdminAuth.require_admin(req),
         {:ok, id} <- parse_int(req[:path_params]["id"]) do
      case GatewayRpc.call(SukhiFedi.Accounts, :set_admin, [id, admin.id, flag]) do
        {:ok, {:ok, account}} -> ok(200, AdminAccount.render(account))
        {:ok, {:error, :not_found}} -> ok(404, %{error: "account_not_found"})
        other -> rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
    end
  end

  # ── reports ──────────────────────────────────────────────────────────────

  def list_reports(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req) do
      q = parse_query(req[:query])
      status = status_filter(q["status"])
      pagination = OffsetPagination.parse(req[:query])

      case GatewayRpc.call(SukhiFedi.Addons.Moderation, :list_reports, [status, pagination]) do
        {:ok, {:ok, {reports, total}}} ->
          page(AdminReport.render_list(reports), pagination, total)

        other ->
          rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  def show_report(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req),
         {:ok, id} <- parse_int(req[:path_params]["id"]) do
      case GatewayRpc.call(SukhiFedi.Addons.Moderation, :get_report, [id]) do
        {:ok, {:ok, report}} -> ok(200, AdminReport.render(report))
        {:ok, {:error, :not_found}} -> ok(404, %{error: "report_not_found"})
        other -> rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
    end
  end

  def resolve_report(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req),
         {:ok, id} <- parse_int(req[:path_params]["id"]) do
      case GatewayRpc.call(SukhiFedi.Addons.Moderation, :resolve_report, [id, admin.id]) do
        {:ok, {:ok, report}} ->
          case GatewayRpc.call(SukhiFedi.Addons.Moderation, :get_report, [report.id]) do
            {:ok, {:ok, hydrated}} -> ok(200, AdminReport.render(hydrated))
            _ -> ok(200, AdminReport.render(report))
          end

        {:ok, {:error, :not_found}} ->
          ok(404, %{error: "report_not_found"})

        other ->
          rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      {:error, :bad_int} -> ok(400, %{error: "invalid_id"})
    end
  end

  # ── domain blocks ────────────────────────────────────────────────────────

  def list_domain_blocks(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req) do
      pagination = OffsetPagination.parse(req[:query])

      case GatewayRpc.call(SukhiFedi.Addons.Moderation, :list_instance_blocks, [pagination]) do
        {:ok, {:ok, {blocks, total}}} ->
          page(AdminDomainBlock.render_list(blocks), pagination, total)

        other ->
          rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  def create_domain_block(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req) do
      body = decode_body(req)
      domain = body |> Map.get("domain") |> normalize_domain()
      severity = body |> Map.get("severity") |> severity_or_default()
      reason = Map.get(body, "reason")

      cond do
        is_nil(domain) ->
          ok(422, %{error: "validation_failed", details: %{domain: ["can't be blank"]}})

        true ->
          case GatewayRpc.call(SukhiFedi.Addons.Moderation, :block_instance, [
                 domain,
                 severity,
                 reason,
                 admin.id
               ]) do
            {:ok, {:ok, block}} -> ok(200, AdminDomainBlock.render(block))
            other -> rpc_error(other)
          end
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  def delete_domain_block(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req) do
      q = parse_query(req[:query])
      domain = q |> Map.get("domain") |> normalize_domain()

      cond do
        is_nil(domain) ->
          ok(422, %{error: "validation_failed", details: %{domain: ["can't be blank"]}})

        true ->
          case GatewayRpc.call(SukhiFedi.Addons.Moderation, :unblock_instance, [domain, admin.id]) do
            {:ok, {:ok, %{domain: d}}} -> ok(200, %{domain: d})
            {:ok, {:error, :not_found}} -> ok(404, %{error: "domain_block_not_found"})
            other -> rpc_error(other)
          end
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  # ── announcements ────────────────────────────────────────────────────────

  def list_announcements(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req) do
      case GatewayRpc.call(SukhiFedi.Announcements, :list_all, []) do
        {:ok, list} when is_list(list) -> ok(200, MastodonAnnouncement.render_list(list))
        other -> rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  def create_announcement(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req) do
      # New announcements go live by default — an admin writing one
      # usually means it now. Pass `"published": false` to keep a draft.
      attrs = Map.put_new(announcement_attrs(decode_body(req)), "published", true)

      case GatewayRpc.call(SukhiFedi.Announcements, :create, [attrs]) do
        {:ok, {:ok, ann}} -> ok(200, MastodonAnnouncement.render(ann))
        {:ok, {:error, %{} = cs}} -> ok(422, %{error: "validation_failed", details: cs_errors(cs)})
        other -> rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  def update_announcement(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req) do
      attrs = announcement_attrs(decode_body(req))

      case GatewayRpc.call(SukhiFedi.Announcements, :update, [req[:path_params]["id"], attrs]) do
        {:ok, {:ok, ann}} -> ok(200, MastodonAnnouncement.render(ann))
        {:ok, {:error, :not_found}} -> ok(404, %{error: "announcement_not_found"})
        {:ok, {:error, %{} = cs}} -> ok(422, %{error: "validation_failed", details: cs_errors(cs)})
        other -> rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  def delete_announcement(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req) do
      case GatewayRpc.call(SukhiFedi.Announcements, :delete, [req[:path_params]["id"]]) do
        {:ok, {:ok, _}} -> ok(200, %{})
        {:ok, {:error, :not_found}} -> ok(404, %{error: "announcement_not_found"})
        other -> rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  # Keep only the fields an announcement understands; the context's
  # changeset casts the ISO datetime strings and booleans. We don't
  # default missing keys so an update touches only what was sent.
  defp announcement_attrs(body) do
    Map.take(body, ["content", "published", "all_day", "starts_at", "ends_at", "published_at"])
  end

  defp cs_errors(%{errors: errors}), do: Map.new(errors, fn {k, {msg, _}} -> {k, msg} end)
  defp cs_errors(_), do: %{}

  # ── stats ────────────────────────────────────────────────────────────────

  def stats(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req) do
      case GatewayRpc.call(SukhiFedi.Stats, :dashboard, []) do
        {:ok, %{} = payload} -> ok(200, payload)
        other -> rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp page(items, pagination, total) do
    ok(200, %{items: items, pagination: OffsetPagination.meta(pagination, total)})
  end

  defp rpc_error({:ok, {:error, :not_found}}), do: ok(404, %{error: "not_found"})
  defp rpc_error({:error, :not_connected}), do: ok(503, %{error: "gateway_not_connected"})

  defp rpc_error({:error, {:badrpc, reason}}),
    do: ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})

  defp rpc_error(_), do: ok(500, %{error: "internal_error"})

  defp decode_body(req) do
    ct = content_type(req[:headers] || [])
    raw = req[:body] || ""

    cond do
      String.contains?(ct, "application/json") ->
        case JSON.decode(raw) do
          {:ok, %{} = m} -> m
          _ -> %{}
        end

      String.contains?(ct, "application/x-www-form-urlencoded") ->
        URI.decode_query(raw)

      true ->
        %{}
    end
  end

  defp content_type(headers) do
    Enum.find_value(headers, "", fn {k, v} ->
      if String.downcase(to_string(k)) == "content-type", do: to_string(v), else: nil
    end)
  end

  defp parse_query(nil), do: %{}
  defp parse_query(""), do: %{}
  defp parse_query(q) when is_binary(q), do: URI.decode_query(q)

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_int}
    end
  end

  defp parse_int(n) when is_integer(n), do: {:ok, n}
  defp parse_int(_), do: {:error, :bad_int}

  defp parse_bool(v) when v in ["true", "1"], do: true
  defp parse_bool(v) when v in ["false", "0"], do: false
  defp parse_bool(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp sanitized_prefix(nil), do: nil
  defp sanitized_prefix(""), do: nil

  defp sanitized_prefix(s) when is_binary(s) do
    trimmed = String.trim(s)
    if trimmed == "", do: nil, else: trimmed
  end

  defp status_filter(s) when s in ["open", "resolved"], do: s
  defp status_filter(_), do: "open"

  defp severity_or_default(s) when s in ["silence", "suspend", "noop"], do: s
  defp severity_or_default(_), do: "suspend"

  defp normalize_domain(nil), do: nil
  defp normalize_domain(""), do: nil

  defp normalize_domain(s) when is_binary(s) do
    trimmed = s |> String.trim() |> String.downcase()
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_domain(_), do: nil

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
