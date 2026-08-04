# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonPush do
  @moduledoc """
  Web Push subscription surface.

      POST   /api/v1/push/subscription    push
      GET    /api/v1/push/subscription    push
      PUT    /api/v1/push/subscription    push
      DELETE /api/v1/push/subscription    push

  Subscription rows are owned by `SukhiFedi.Addons.WebPush`.
  Mastodon's model is one subscription *per access token*; we store
  one per (account, endpoint) and surface the most-recent row for
  GET/PUT/DELETE. Push delivery itself is a future task (the addon's
  `send_notification/2` is still a stub).

  The server's VAPID public key is read from
  `:sukhi_fedi, :vapid_public_key` config; if unset, POST responds
  with the `server_key: null`.
  """

  use SukhiApi.Capability, addon: :web_push

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.Id

  @impl true
  def routes do
    [
      {:post, "/api/v1/push/subscription", &create/1, scope: "push"},
      {:get, "/api/v1/push/subscription", &show/1, scope: "push"},
      {:put, "/api/v1/push/subscription", &update/1, scope: "push"},
      {:delete, "/api/v1/push/subscription", &delete/1, scope: "push"}
    ]
  end

  def create(req) do
    with_viewer(req, fn v ->
      body = decode_body(req)
      sub = body["subscription"] || %{}
      data = body["data"] || %{}
      alerts = data["alerts"] || %{}

      endpoint = sub["endpoint"]
      keys = sub["keys"] || %{}
      p256dh = keys["p256dh"]
      auth = keys["auth"]

      cond do
        not is_binary(endpoint) ->
          ok(422, %{error: "missing_subscription_endpoint"})

        not is_binary(p256dh) or not is_binary(auth) ->
          ok(422, %{error: "missing_subscription_keys"})

        true ->
          case GatewayRpc.call(SukhiFedi.Addons.WebPush, :subscribe, [
                 v.id,
                 endpoint,
                 p256dh,
                 auth,
                 alerts
               ]) do
            {:ok, {:ok, row}} -> ok(200, render(row))
            {:ok, {:error, _}} -> ok(422, %{error: "validation_failed"})
            e -> rpc_error(e)
          end
      end
    end)
  end

  def show(req) do
    with_viewer(req, fn v ->
      case GatewayRpc.call(SukhiFedi.Addons.WebPush, :get_subscription_for, [v.id]) do
        {:ok, nil} -> ok(404, %{error: "not_found"})
        {:ok, row} -> ok(200, render(row))
        e -> rpc_error(e)
      end
    end)
  end

  def update(req) do
    # Mastodon's PUT only updates the alerts map; the subscription is
    # otherwise re-issued by re-POSTing. We mirror that: update writes
    # alerts on the current row.
    with_viewer(req, fn v ->
      body = decode_body(req)
      alerts = (body["data"] || %{})["alerts"] || %{}

      case GatewayRpc.call(SukhiFedi.Addons.WebPush, :get_subscription_for, [v.id]) do
        {:ok, nil} ->
          ok(404, %{error: "not_found"})

        {:ok, row} ->
          case GatewayRpc.call(SukhiFedi.Addons.WebPush, :subscribe, [
                 v.id,
                 row.endpoint,
                 row.p256dh_key,
                 row.auth_key,
                 alerts
               ]) do
            {:ok, {:ok, updated}} -> ok(200, render(updated))
            _ -> ok(422, %{error: "validation_failed"})
          end

        e ->
          rpc_error(e)
      end
    end)
  end

  def delete(req) do
    with_viewer(req, fn v ->
      case GatewayRpc.call(SukhiFedi.Addons.WebPush, :get_subscription_for, [v.id]) do
        {:ok, nil} ->
          ok(200, %{})

        {:ok, row} ->
          GatewayRpc.call(SukhiFedi.Addons.WebPush, :unsubscribe, [row.endpoint])
          ok(200, %{})

        e ->
          rpc_error(e)
      end
    end)
  end

  defp render(row) do
    server_key =
      case GatewayRpc.call(SukhiFedi.Addons.WebPush, :server_key, []) do
        {:ok, k} when is_binary(k) -> k
        _ -> nil
      end

    # `direct_types` is ours, not Mastodon's. The server decides which
    # notification types may ever wake somebody, and the web client reads
    # that list from here rather than keeping its own copy — two literals
    # would drift, and a drift here is a phone buzzing for a favourite.
    direct_types =
      case GatewayRpc.call(SukhiFedi.Addons.WebPush, :direct_types, []) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    %{
      id: Id.encode(row.id),
      endpoint: row.endpoint,
      alerts: row.alerts || %{},
      server_key: server_key,
      direct_types: direct_types
    }
  end

  defp with_viewer(req, fun) do
    case req[:assigns][:current_account] do
      nil -> ok(403, %{error: "this endpoint requires a user-bound token"})
      %{} = v -> fun.(v)
    end
  end

  defp decode_body(req) do
    case req[:body] do
      nil -> %{}
      "" -> %{}
      body when is_binary(body) ->
        case JSON.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> URI.decode_query(body)
        end

      body when is_map(body) ->
        body
    end
  end

  defp rpc_error({:error, :not_connected}), do: ok(503, %{error: "gateway_not_connected"})

  defp rpc_error({:error, {:badrpc, r}}),
    do: ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

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
