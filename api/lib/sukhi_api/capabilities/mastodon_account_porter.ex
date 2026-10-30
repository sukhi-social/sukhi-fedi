# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonAccountPorter do
  @moduledoc """
  Export / import of the caller's own follows, blocks and mutes, as the
  one-column CSV Mastodon uses (`Account address`).

    * `GET  /api/v1/accounts/export/{following,blocks,mutes}` — `text/csv`
    * `POST /api/v1/accounts/import/{following,blocks,mutes}` — body is
      `{"data": "<csv text>"}` (or the CSV itself as `text/csv`); answers
      `{"imported": n, "skipped": n, "unresolved": [..]}`

  Each route is gated by the scope of the list it touches (`read:follows`
  / `write:follows`, …). Parsing, caps, resolution and the writes live on
  the gateway (`SukhiFedi.AccountPorter`); this is transport only.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc

  # Resolving unknown remote addresses over WebFinger can outlast the default
  # RPC timeout; the gateway caps how many it tries.
  @import_timeout 90_000

  @impl true
  def routes do
    [
      {:get, "/api/v1/accounts/export/following", &export_following/1, scope: "read:follows"},
      {:get, "/api/v1/accounts/export/blocks", &export_blocks/1, scope: "read:blocks"},
      {:get, "/api/v1/accounts/export/mutes", &export_mutes/1, scope: "read:mutes"},
      {:post, "/api/v1/accounts/import/following", &import_following/1, scope: "write:follows"},
      {:post, "/api/v1/accounts/import/blocks", &import_blocks/1, scope: "write:blocks"},
      {:post, "/api/v1/accounts/import/mutes", &import_mutes/1, scope: "write:mutes"}
    ]
  end

  def export_following(req), do: export(req, :following)
  def export_blocks(req), do: export(req, :blocks)
  def export_mutes(req), do: export(req, :mutes)

  def import_following(req), do: import_list(req, :following)
  def import_blocks(req), do: import_list(req, :blocks)
  def import_mutes(req), do: import_list(req, :mutes)

  # ── export ─────────────────────────────────────────────────────────────────

  defp export(req, kind) do
    with_account(req, fn %{id: id} ->
      case GatewayRpc.run(SukhiFedi.AccountPorter, :export, [id, kind]) do
        {:ok, csv} ->
          {:ok,
           %{
             status: 200,
             body: csv,
             headers: [
               {"content-type", "text/csv; charset=utf-8"},
               {"content-disposition", ~s(attachment; filename="#{kind}.csv")}
             ]
           }}

        {:error, :not_found} ->
          ok(404, %{error: "account_not_found"})

        {:unavailable, why} ->
          ok(503, GatewayRpc.unavailable_body(why))

        _ ->
          ok(500, %{error: "internal_error"})
      end
    end)
  end

  # ── import ─────────────────────────────────────────────────────────────────

  defp import_list(req, kind) do
    with_account(req, fn %{id: id} ->
      case GatewayRpc.run(SukhiFedi.AccountPorter, :import_csv, [id, kind, csv_of(req)], @import_timeout) do
        {:ok, result} ->
          ok(200, result)

        {:error, :too_large} ->
          ok(413, %{error: "too_large"})

        {:error, :too_many} ->
          ok(422, %{error: "too_many_rows"})

        {:error, :not_found} ->
          ok(404, %{error: "account_not_found"})

        {:unavailable, why} ->
          ok(503, GatewayRpc.unavailable_body(why))

        _ ->
          ok(500, %{error: "internal_error"})
      end
    end)
  end

  # JSON `{"data": "…"}` from clients that build requests as JSON; anything
  # else is taken as the CSV itself. Either way a binary — the gateway is
  # the one place that reads it.
  defp csv_of(req) do
    body = req[:body] || ""

    case String.contains?(content_type(req[:headers] || []), "application/json") do
      true ->
        case JSON.decode(body) do
          {:ok, %{"data" => data}} when is_binary(data) -> data
          _ -> ""
        end

      false ->
        body
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Every route here is the caller acting on their own lists; a
  # client_credentials token has no user identity and is refused once, here.
  defp with_account(req, fun) do
    case req[:assigns][:current_account] do
      nil -> ok(403, %{error: "this endpoint requires a user-bound token"})
      %{} = account -> fun.(account)
    end
  end

  defp content_type(headers) do
    Enum.find_value(headers, "", fn {k, v} ->
      if String.downcase(to_string(k)) == "content-type", do: to_string(v), else: nil
    end)
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
