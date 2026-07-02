# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonStatuses do
  @moduledoc """
  Mastodon `/api/v1/statuses/*` capability.

      POST   /api/v1/statuses              scope: write:statuses
      GET    /api/v1/statuses/:id          (public)
      DELETE /api/v1/statuses/:id          scope: write:statuses
      GET    /api/v1/statuses/:id/context  (public)

  `media_ids[]` resolution + attachment happens inside
  `SukhiFedi.Notes.create_status/2`'s `Ecto.Multi` alongside the note
  insert + tag extraction + outbox enqueue.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc
  alias SukhiApi.StatusHydration
  alias SukhiApi.Views.{MastodonScheduledStatus, MastodonStatus}

  @impl true
  def routes do
    [
      {:post, "/api/v1/statuses", &create/1, scope: "write:statuses"},
      {:get, "/api/v1/statuses/:id", &show/1},
      {:delete, "/api/v1/statuses/:id", &delete/1, scope: "write:statuses"},
      {:get, "/api/v1/statuses/:id/context", &context/1}
    ]
  end

  # ── POST /api/v1/statuses ────────────────────────────────────────────────

  def create(req) do
    %{current_account: viewer} = req[:assigns]

    case viewer do
      nil ->
        ok(403, %{error: "this endpoint requires a user-bound token"})

      %{} = v ->
        attrs = decode_status_attrs(req)

        # A `scheduled_at` turns this into a deferred publish: store the
        # params + an Oban job and return a ScheduledStatus, rather than
        # posting now. Everything else about the attrs is identical — the
        # worker replays them through this same create path at publish time.
        case attrs["scheduled_at"] || attrs[:scheduled_at] do
          nil -> create_now(v, attrs)
          at -> create_scheduled(v, attrs, at)
        end
    end
  end

  defp create_now(v, attrs) do
    case GatewayRpc.call(SukhiFedi.Notes, :create_status, [v, attrs]) do
      {:ok, {:ok, note}} ->
        maybe_stream_dm(note)
        rendered = StatusHydration.one(note, v)
        maybe_stream_new_post(note, rendered, v)
        ok(200, rendered)

      {:ok, {:error, {:validation, errors}}} ->
        ok(422, %{error: "validation_failed", details: errors})

      {:ok, {:error, :media_not_owned}} ->
        ok(422, %{error: "media_not_owned"})

      {:ok, {:error, reason}} ->
        ok(422, %{error: inspect(reason)})

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      {:error, {:badrpc, r}} ->
        ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

      _ ->
        ok(500, %{error: "internal_error"})
    end
  end

  defp create_scheduled(v, attrs, at) do
    case GatewayRpc.call(SukhiFedi.ScheduledStatuses, :create, [v, attrs, at]) do
      {:ok, {:ok, scheduled}} ->
        ok(200, MastodonScheduledStatus.render(scheduled))

      {:ok, {:error, :too_soon}} ->
        ok(422, %{error: "scheduled_at must be at least 5 minutes in the future"})

      {:ok, {:error, :invalid_time}} ->
        ok(422, %{error: "scheduled_at is not a valid datetime"})

      {:ok, {:error, reason}} ->
        ok(422, %{error: inspect(reason)})

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      {:error, {:badrpc, r}} ->
        ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

      _ ->
        ok(500, %{error: "internal_error"})
    end
  end

  # DMs push a `conversation` event to each local participant's `direct`
  # stream. Off the response path and best-effort: streaming must never
  # delay or fail a post.
  defp maybe_stream_dm(%{visibility: "direct", conversation_ap_id: cid}) when is_binary(cid) do
    Task.start(fn -> SukhiApi.Capabilities.MastodonConversations.stream_new_dm(cid) end)
    :ok
  end

  defp maybe_stream_dm(_), do: :ok

  # Public な新規投稿を streaming に流す（local timeline + フォロワーの home）。views は
  # この node にあるので、レスポンス用にレンダ済みの status をそのまま gateway の
  # Streaming.publish_new_post へ渡す（→ stream.new_post → NatsListener が SSE/WS と
  # WebTransport エッジ karutte の両方へ fanout）。best-effort・レスポンス経路の外。
  # public のみ＝可視性ゲート不要（public は local/home どちらにも出てよい）。unlisted /
  # followers-only / direct の live 配信は後回し（DM は maybe_stream_dm）。
  defp maybe_stream_new_post(%{visibility: "public"}, rendered, %{username: username})
       when is_map(rendered) and is_binary(username) do
    actor_id = "https://#{SukhiApi.Config.domain!()}/users/#{username}"
    Task.start(fn -> GatewayRpc.call(SukhiFedi.Streaming, :publish_new_post, [rendered, actor_id]) end)
    :ok
  end

  defp maybe_stream_new_post(_note, _rendered, _v), do: :ok

  defp decode_status_attrs(req) do
    headers = req[:headers] || []
    ct = content_type(headers)

    cond do
      String.contains?(ct, "application/json") ->
        case JSON.decode(req[:body] || "") do
          {:ok, %{} = m} -> m
          _ -> %{}
        end

      String.contains?(ct, "application/x-www-form-urlencoded") ->
        URI.decode_query(req[:body] || "")
        |> normalize_form_arrays()

      String.contains?(ct, "multipart/form-data") ->
        case SukhiApi.Multipart.parse_multifile(req[:body] || "", ct, max_file_bytes: 0) do
          {:ok, %{fields: fields}} -> normalize_form_arrays(fields)
          _ -> %{}
        end

      true ->
        %{}
    end
  end

  # Mastodon clients send media_ids[]=1&media_ids[]=2; URI.decode_query
  # returns the LAST one as a single value. Re-collect.
  defp normalize_form_arrays(map) do
    map
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      case String.replace_suffix(k, "[]", "") do
        ^k -> Map.put(acc, k, v)
        base -> Map.update(acc, base, [v], fn existing -> List.wrap(existing) ++ [v] end)
      end
    end)
  end

  # ── GET /api/v1/statuses/:id ─────────────────────────────────────────────

  def show(req) do
    id = req[:path_params]["id"]
    viewer = req[:assigns][:current_account]
    viewer_id = viewer && Map.get(viewer, :id)

    case GatewayRpc.call(SukhiFedi.Notes, :get_note, [id, viewer_id]) do
      {:ok, {:ok, note}} -> ok(200, StatusHydration.one(note, viewer))
      {:ok, {:error, :not_found}} -> ok(404, %{error: "not_found"})
      {:error, :not_connected} -> ok(503, %{error: "gateway_not_connected"})
      {:error, {:badrpc, r}} -> ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})
      _ -> ok(500, %{error: "internal_error"})
    end
  end

  # ── DELETE /api/v1/statuses/:id ──────────────────────────────────────────

  def delete(req) do
    %{current_account: viewer} = req[:assigns]
    id = req[:path_params]["id"]

    case viewer do
      nil ->
        ok(403, %{error: "this endpoint requires a user-bound token"})

      %{} = v ->
        case GatewayRpc.call(SukhiFedi.Notes, :delete_note, [v, id]) do
          {:ok, {:ok, note}} ->
            # Mastodon quirk: returns the deleted status's last form
            ok(200, MastodonStatus.render(note))

          {:ok, {:error, :not_found}} ->
            ok(404, %{error: "not_found"})

          {:ok, {:error, :forbidden}} ->
            ok(403, %{error: "forbidden"})

          {:error, :not_connected} ->
            ok(503, %{error: "gateway_not_connected"})

          {:error, {:badrpc, r}} ->
            ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

          _ ->
            ok(500, %{error: "internal_error"})
        end
    end
  end

  # ── GET /api/v1/statuses/:id/context ─────────────────────────────────────

  def context(req) do
    id = req[:path_params]["id"]
    viewer = req[:assigns][:current_account]
    viewer_id = viewer && Map.get(viewer, :id)

    case GatewayRpc.call(SukhiFedi.Notes, :context, [id, viewer_id]) do
      {:ok, {:ok, %{ancestors: a, descendants: d}}} ->
        ok(200, %{
          ancestors: StatusHydration.many(a, viewer),
          descendants: StatusHydration.many(d, viewer)
        })

      {:ok, {:error, :not_found}} ->
        ok(404, %{error: "not_found"})

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      {:error, {:badrpc, r}} ->
        ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

      _ ->
        ok(500, %{error: "internal_error"})
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

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
