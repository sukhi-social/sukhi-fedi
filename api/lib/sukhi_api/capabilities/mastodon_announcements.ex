# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonAnnouncements do
  @moduledoc """
  Mastodon announcements surface — the reader side.

      GET  /api/v1/announcements              read
      POST /api/v1/announcements/:id/dismiss  write

  Returns the announcements the bound account should see right now,
  each tagged with whether they've dismissed it. Authoring lives on the
  admin surface (`/api/admin/announcements`), not here. Reactions
  (`PUT/DELETE /:id/reactions/:name`) are intentionally not implemented
  yet; the rendered `reactions` array is always present but empty, which
  keeps clients happy.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.MastodonAnnouncement

  @impl true
  def routes do
    [
      {:get, "/api/v1/announcements", &index/1, scope: "read"},
      {:post, "/api/v1/announcements/:id/dismiss", &dismiss/1, scope: "write"}
    ]
  end

  def index(req) do
    with_viewer(req, fn v ->
      case GatewayRpc.call(SukhiFedi.Announcements, :active_for, [v.id]) do
        {:ok, pairs} when is_list(pairs) -> ok(200, MastodonAnnouncement.render_pairs(pairs))
        e -> rpc_error(e)
      end
    end)
  end

  def dismiss(req) do
    with_viewer(req, fn v ->
      case GatewayRpc.call(SukhiFedi.Announcements, :dismiss, [v.id, req[:path_params]["id"]]) do
        {:ok, :ok} -> ok(200, %{})
        {:ok, {:error, :not_found}} -> ok(404, %{error: "not_found"})
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
