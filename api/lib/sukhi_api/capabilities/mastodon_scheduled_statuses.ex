# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonScheduledStatuses do
  @moduledoc """
  Mastodon `/api/v1/scheduled_statuses` capability.

      GET    /api/v1/scheduled_statuses       read:statuses
      GET    /api/v1/scheduled_statuses/:id   read:statuses
      PUT    /api/v1/scheduled_statuses/:id   write:statuses
      DELETE /api/v1/scheduled_statuses/:id   write:statuses

  Scheduling itself happens on `POST /api/v1/statuses` with a
  `scheduled_at` (see `MastodonStatuses.create/1`), which returns a
  ScheduledStatus instead of a Status. This capability lists, retimes
  (PUT moves `scheduled_at`) and cancels (DELETE removes the row and the
  pending Oban job) those schedules.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.MastodonScheduledStatus

  @impl true
  def routes do
    [
      {:get, "/api/v1/scheduled_statuses", &index/1, scope: "read:statuses"},
      {:get, "/api/v1/scheduled_statuses/:id", &show/1, scope: "read:statuses"},
      {:put, "/api/v1/scheduled_statuses/:id", &update/1, scope: "write:statuses"},
      {:delete, "/api/v1/scheduled_statuses/:id", &delete/1, scope: "write:statuses"}
    ]
  end

  def index(req) do
    with_viewer(req, fn v ->
      case GatewayRpc.run(SukhiFedi.ScheduledStatuses, :list, [v.id]) do
        {:ok, list} when is_list(list) -> ok(200, MastodonScheduledStatus.render_list(list))
        e -> rpc_error(e)
      end
    end)
  end

  def show(req) do
    with_viewer(req, fn v ->
      case GatewayRpc.run(SukhiFedi.ScheduledStatuses, :get, [v.id, req[:path_params]["id"]]) do
        {:ok, scheduled} -> ok(200, MastodonScheduledStatus.render(scheduled))
        {:error, :not_found} -> ok(404, %{error: "not_found"})
        e -> rpc_error(e)
      end
    end)
  end

  def update(req) do
    with_viewer(req, fn v ->
      id = req[:path_params]["id"]
      scheduled_at = decode_body(req)["scheduled_at"]

      case GatewayRpc.run(SukhiFedi.ScheduledStatuses, :reschedule, [v.id, id, scheduled_at]) do
        {:ok, scheduled} -> ok(200, MastodonScheduledStatus.render(scheduled))
        {:error, :not_found} -> ok(404, %{error: "not_found"})
        {:error, :too_soon} -> ok(422, %{error: "scheduled_at must be at least 5 minutes in the future"})
        {:error, :invalid_time} -> ok(422, %{error: "scheduled_at is not a valid datetime"})
        e -> rpc_error(e)
      end
    end)
  end

  def delete(req) do
    with_viewer(req, fn v ->
      case GatewayRpc.run(SukhiFedi.ScheduledStatuses, :cancel, [v.id, req[:path_params]["id"]]) do
        {:ok, _} -> ok(200, %{})
        {:error, :not_found} -> ok(404, %{error: "not_found"})
        e -> rpc_error(e)
      end
    end)
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
