# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MisskeyDrafts do
  @moduledoc """
  Server-side compose draft — the cross-device half of the SPA's local
  `sf.compose_draft`. Misskey-native surface (Mastodon has no draft API),
  the first seed of the `:misskey_api` addon.

      GET    /api/i/notes/drafts   read:statuses
      PUT    /api/i/notes/drafts   write:statuses
      DELETE /api/i/notes/drafts   write:statuses

  One draft per account, so the surface is a single resource, not a list:
  GET reads it (204 when empty), PUT replaces it, DELETE discards it. The
  draft is strictly per-account and **never federated** — ownership and
  the no-federation property both live in `SukhiFedi.NoteDrafts`; this
  capability only shapes HTTP. The composer prunes the draft on a
  successful post (a DELETE after `POST /api/v1/statuses`).
  """

  use SukhiApi.Capability, addon: :misskey_api

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.MisskeyNoteDraft

  @impl true
  def routes do
    [
      {:get, "/api/i/notes/drafts", &show/1, scope: "read:statuses"},
      {:put, "/api/i/notes/drafts", &upsert/1, scope: "write:statuses"},
      {:delete, "/api/i/notes/drafts", &delete/1, scope: "write:statuses"}
    ]
  end

  def show(req) do
    with_viewer(req, fn v ->
      case GatewayRpc.run(SukhiFedi.NoteDrafts, :get, [v.id]) do
        {:ok, nil} -> ok(204, %{})
        {:ok, draft} -> ok(200, MisskeyNoteDraft.render(draft))
        e -> rpc_error(e)
      end
    end)
  end

  def upsert(req) do
    with_viewer(req, fn v ->
      attrs = draft_attrs(decode_body(req))

      case GatewayRpc.run(SukhiFedi.NoteDrafts, :upsert, [v.id, attrs]) do
        {:ok, draft} -> ok(200, MisskeyNoteDraft.render(draft))
        {:error, _changeset} -> ok(422, %{error: "invalid_draft"})
        e -> rpc_error(e)
      end
    end)
  end

  def delete(req) do
    with_viewer(req, fn v ->
      case GatewayRpc.run(SukhiFedi.NoteDrafts, :delete, [v.id]) do
        {:ok, :ok} -> ok(200, %{})
        e -> rpc_error(e)
      end
    end)
  end

  # Map the composer's body to the context's string-keyed attrs. The
  # client posts `useSpoiler`; the stored shape keeps only `spoiler`
  # (empty = fold off), so an off fold drops the spoiler text rather than
  # storing a hidden one.
  defp draft_attrs(body) do
    %{
      "text" => body["text"] || "",
      "spoiler" => if(body["useSpoiler"], do: body["spoiler"] || "", else: ""),
      "sensitive" => !!body["sensitive"],
      "visibility" => body["visibility"] || "public"
    }
  end

  defp with_viewer(req, fun) do
    %{current_account: viewer} = req[:assigns]

    case viewer do
      nil -> ok(403, %{error: "this endpoint requires a user-bound token"})
      %{} = v -> fun.(v)
    end
  end

  defp decode_body(req) do
    case req[:body] do
      nil ->
        %{}

      "" ->
        %{}

      body when is_binary(body) ->
        case JSON.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> URI.decode_query(body)
        end

      body when is_map(body) ->
        body
    end
  end

  defp rpc_error({:unavailable, why}), do: ok(503, GatewayRpc.unavailable_body(why))

  defp rpc_error(_), do: ok(500, %{error: "internal_error"})

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
