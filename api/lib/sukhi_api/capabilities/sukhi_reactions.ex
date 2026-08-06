# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.SukhiReactions do
  @moduledoc """
  Misskey-style emoji reactions (Sukhi extension; not in the Mastodon
  spec). Mastodon's `POST /favourite` stays as the ⭐ shortcut so
  Mastodon clients keep working.

      PUT    /api/v1/sukhi/statuses/:id/react/:emoji   write:favourites
      DELETE /api/v1/sukhi/statuses/:id/react/:emoji   write:favourites

  `:emoji` is URL-encoded. Either a Unicode glyph (e.g. `%F0%9F%A6%8A`
  for 🦊) or a shortcode like `:blobcat@misskey.io:`.

  Returns the updated Status JSON on success; idempotent.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.MastodonStatus

  @max_emoji_bytes 64

  @impl true
  def routes do
    [
      {:put, "/api/v1/sukhi/statuses/:id/react/:emoji", &react/1,
       scope: "write:favourites"},
      {:delete, "/api/v1/sukhi/statuses/:id/react/:emoji", &unreact/1,
       scope: "write:favourites"}
    ]
  end

  def react(req), do: do_react(req, :react)
  def unreact(req), do: do_react(req, :unreact)

  defp do_react(req, fun) do
    %{current_account: viewer} = req[:assigns]
    id = req[:path_params]["id"]
    raw = req[:path_params]["emoji"] || ""

    with %{} = v <- viewer || :no_viewer,
         {:ok, emoji} <- decode_emoji(raw),
         {:ok, {:ok, note}} <- GatewayRpc.call(SukhiFedi.Notes, fun, [v, id, emoji]) do
      # Clips が「自分の Clip に自分でリアクション」でピンを表すので、
      # 別タブ/端末にも見た目を追いつかせるには通常の DM と同じ道が要る。
      SukhiApi.Capabilities.MastodonConversations.maybe_stream_dm(note)
      ok(200, render_status_with_context(v, note))
    else
      :no_viewer -> ok(403, %{error: "this endpoint requires a user-bound token"})
      {:error, :bad_emoji} -> ok(400, %{error: "bad_emoji"})
      {:ok, {:error, :not_found}} -> ok(404, %{error: "not_found"})
      {:ok, {:error, :forbidden}} -> ok(403, %{error: "forbidden"})
      {:error, :not_connected} -> ok(503, %{error: "gateway_not_connected"})
      {:error, {:badrpc, r}} -> ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})
      _ -> ok(500, %{error: "internal_error"})
    end
  end

  defp decode_emoji(raw) when is_binary(raw) do
    decoded = URI.decode(raw)

    cond do
      decoded == "" -> {:error, :bad_emoji}
      byte_size(decoded) > @max_emoji_bytes -> {:error, :bad_emoji}
      true -> {:ok, decoded}
    end
  end

  defp render_status_with_context(viewer, note) do
    counts =
      case GatewayRpc.call(SukhiFedi.Notes, :counts_for_note, [note.id]) do
        {:ok, %{} = m} -> m
        _ -> %{}
      end

    flags =
      case GatewayRpc.call(SukhiFedi.Notes, :viewer_flags, [viewer.id, note.id]) do
        {:ok, %{} = m} -> m
        _ -> %{}
      end

    reactions =
      case GatewayRpc.call(SukhiFedi.Notes, :reactions_for_notes, [[note.id], viewer.id]) do
        {:ok, m} when is_map(m) -> Map.get(m, note.id, [])
        _ -> []
      end

    MastodonStatus.render(note, %{counts: counts, viewer: flags, reactions: reactions})
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
