# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.AdminEmojis do
  @moduledoc """
  Bulk custom-emoji import for admins — `/api/admin/emojis`, not
  Mastodon-compatible. Same gates as the rest of `/api/admin/*`: an OAuth
  bearer with `admin:write` (router) and `is_admin` (`AdminAuth`).

      POST /api/admin/emojis
      {"emojis": [{"shortcode": "blobcat", "image_url": "https://…/blobcat.png",
                   "category": "Cats", "aliases": ["neko"]}, …],
       "dry_run": false}

  It is an upsert keyed by shortcode (a local emoji; `domain` is not
  accepted here): sending an existing shortcode replaces its image, category
  and aliases, so a pack can be re-sent safely. Items are checked first and
  the valid ones are written in one transaction; an invalid item is reported
  and skipped, not fatal. `dry_run: true` checks and reports without writing.

  The answer is 200 with the outcome of every item, in the order sent:

      {"imported": 2, "failed": 1, "dry_run": false,
       "results": [{"index": 0, "shortcode": "blobcat", "status": "ok"},
                   {"index": 1, "shortcode": "x", "status": "error",
                    "error": "invalid_emoji_attributes"}, …]}

  Reading and validating live on the gateway's `SukhiFedi.CustomEmojis`
  (`import_many/3`); this module only gates, decodes and renders.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.{AdminAuth, GatewayRpc}

  # Mirrors SukhiFedi.CustomEmojis @max_import, for the error message only —
  # the gateway is what enforces it.
  @max_import 2_000

  @impl true
  def routes do
    [{:post, "/api/admin/emojis", &import_emojis/1, scope: "admin:write"}]
  end

  def import_emojis(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req),
         {:ok, items, dry_run?} <- parse(req) do
      case GatewayRpc.call(SukhiFedi.CustomEmojis, :import_many, [items, admin.id, [dry_run: dry_run?]]) do
        {:ok, {:ok, summary}} -> ok(200, render(summary))
        {:ok, {:error, :empty}} -> ok(400, %{error: "emojis_empty"})
        {:ok, {:error, :too_many}} -> ok(413, %{error: "too_many", max: @max_import})
        other -> rpc_error(other)
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
      {:error, :emojis_required} -> ok(400, %{error: "emojis_required"})
    end
  end

  defp parse(req) do
    case decode_body(req) do
      %{"emojis" => items} = body when is_list(items) -> {:ok, items, body["dry_run"] in [true, "true"]}
      _ -> {:error, :emojis_required}
    end
  end

  defp render(%{} = s) do
    %{
      imported: s.imported,
      failed: s.failed,
      dry_run: s.dry_run,
      results: Enum.map(s.results, &render_result/1)
    }
  end

  defp render_result(%{status: :ok} = r),
    do: %{index: r.index, shortcode: r.shortcode, status: "ok"}

  defp render_result(r),
    do: %{index: r.index, shortcode: r.shortcode, status: "error", error: to_string(r.error)}

  defp rpc_error({:error, :not_connected}), do: ok(503, %{error: "gateway_not_connected"})

  defp rpc_error({:error, {:badrpc, reason}}),
    do: ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})

  defp rpc_error(_), do: ok(500, %{error: "internal_error"})

  # JSON only: this endpoint takes a list of objects, which a form cannot carry.
  defp decode_body(req) do
    content_type =
      Enum.find_value(req[:headers] || [], "", fn {k, v} ->
        if String.downcase(to_string(k)) == "content-type", do: to_string(v)
      end)

    with true <- String.contains?(content_type, "application/json"),
         {:ok, %{} = body} <- JSON.decode(req[:body] || "") do
      body
    else
      _ -> %{}
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
