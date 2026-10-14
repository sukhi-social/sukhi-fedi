# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.NodeinfoMonitor do
  @moduledoc """
  Management API for the NodeInfo monitor bot.

  Routes:

      POST   /api/v1/monitors            {"domain": "..."}  → register
      GET    /api/v1/monitors                              → list
      GET    /api/v1/monitors/:id                          → show
      DELETE /api/v1/monitors/:id                          → deactivate

  All handlers delegate to `SukhiFedi.Monitor.*` on the gateway node
  via `SukhiApi.GatewayRpc`. A disconnected or crashed gateway results
  in 503 so the client can retry.
  """

  use SukhiApi.Capability, addon: :nodeinfo_monitor

  alias SukhiApi.GatewayRpc

  @gateway_mod SukhiFedi.Addons.NodeinfoMonitor

  @impl true
  def routes do
    [
      {:post, "/api/v1/monitors", &register/1},
      {:get, "/api/v1/monitors", &list/1},
      {:get, "/api/v1/monitors/:id", &show/1},
      {:delete, "/api/v1/monitors/:id", &deactivate/1}
    ]
  end

  def register(req) do
    with {:ok, body} <- decode_body(req),
         {:ok, domain} when is_binary(domain) <- {:ok, body["domain"]},
         {:ok, mi} <- GatewayRpc.run(@gateway_mod, :register, [domain]) do
      ok(201, summarize(mi))
    else
      {:error, :bad_json} ->
        err(400, %{error: "invalid_json"})

      {:error, reason} ->
        err(422, %{error: "register_failed", detail: inspect(reason)})

      {:unavailable, why} ->
        err(503, GatewayRpc.unavailable_body(why))

      _ ->
        err(400, %{error: "missing_domain"})
    end
  end

  def list(_req) do
    case GatewayRpc.run(@gateway_mod, :list, []) do
      {:ok, list} when is_list(list) ->
        ok(200, %{monitors: Enum.map(list, &summarize/1)})

      {:unavailable, why} ->
        err(503, GatewayRpc.unavailable_body(why))
    end
  end

  def show(req) do
    with %{"id" => id} <- req[:path_params] || %{},
         {:ok, iid} <- parse_int(id),
         {:ok, mi} when not is_nil(mi) <- GatewayRpc.run(@gateway_mod, :get, [iid]) do
      ok(200, summarize(mi))
    else
      {:ok, nil} -> err(404, %{error: "not_found"})
      {:unavailable, why} -> err(503, GatewayRpc.unavailable_body(why))
      _ -> err(400, %{error: "invalid_id"})
    end
  end

  def deactivate(req) do
    with %{"id" => id} <- req[:path_params] || %{},
         {:ok, iid} <- parse_int(id),
         {:ok, _} <- GatewayRpc.run(@gateway_mod, :deactivate, [iid]) do
      ok(204, nil)
    else
      {:error, :bad_int} -> err(400, %{error: "invalid_id"})
      {:error, :not_found} -> err(404, %{error: "not_found"})
      {:error, reason} -> err(422, %{error: inspect(reason)})
      {:unavailable, why} -> err(503, GatewayRpc.unavailable_body(why))
      _ -> err(400, %{error: "invalid_id"})
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp decode_body(req) do
    case req[:body] do
      nil ->
        {:ok, %{}}

      "" ->
        {:ok, %{}}

      body when is_binary(body) ->
        case JSON.decode(body) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> {:error, :bad_json}
        end
    end
  end

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} -> {:ok, i}
      _ -> {:error, :bad_int}
    end
  end

  defp parse_int(_), do: {:error, :bad_int}

  defp summarize(%{} = mi) do
    %{
      id: Map.get(mi, :id),
      domain: Map.get(mi, :domain),
      last_polled_at: Map.get(mi, :last_polled_at),
      last_version: Map.get(mi, :last_version),
      software_name: Map.get(mi, :software_name),
      consecutive_failures: Map.get(mi, :consecutive_failures),
      inactive: Map.get(mi, :inactive)
    }
  end

  defp ok(status, nil) do
    {:ok, %{status: status, body: "", headers: []}}
  end

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end

  defp err(status, body_map), do: ok(status, body_map)
end
