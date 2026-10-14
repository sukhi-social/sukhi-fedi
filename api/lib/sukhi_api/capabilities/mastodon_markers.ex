# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonMarkers do
  @moduledoc """
  `/api/v1/markers` — per-account, per-timeline read-position sync.

      GET  /api/v1/markers?timeline[]=home&timeline[]=notifications
      POST /api/v1/markers

  Used by Mastodon clients (Moshidon, Ivory, Tusky, ...) to keep
  "where did I leave off" in sync between devices. Each POST bumps
  `version` — clients use it as an opportunistic conflict marker.

  Response shape (Mastodon-compatible):

      {
        "home":          {"last_read_id": "...", "version": N, "updated_at": "..."},
        "notifications": {"last_read_id": "...", "version": N, "updated_at": "..."}
      }

  Timelines with no marker for the viewer are simply omitted from the
  response (Mastodon returns `{}` in that case).
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.GatewayRpc

  @timelines ~w(home notifications)

  @impl true
  def routes do
    [
      {:get, "/api/v1/markers", &index/1, scope: "read:statuses"},
      {:post, "/api/v1/markers", &write/1, scope: "write:statuses"}
    ]
  end

  def index(req) do
    with_viewer(req, fn v ->
      timelines = extract_timelines(req[:query])

      case GatewayRpc.run(SukhiFedi.Markers, :get, [v.id, timelines]) do
        {:ok, %{} = markers} -> ok(200, render(markers))
        other -> rpc_error(other)
      end
    end)
  end

  def write(req) do
    with_viewer(req, fn v ->
      updates = extract_updates(decode_body(req))

      results =
        Enum.reduce(updates, %{}, fn {tl, last_read_id}, acc ->
          case GatewayRpc.run(SukhiFedi.Markers, :upsert, [v.id, tl, last_read_id]) do
            {:ok, marker} -> Map.put(acc, tl, marker)
            _ -> acc
          end
        end)

      ok(200, render(results))
    end)
  end

  # ── render ───────────────────────────────────────────────────────────────

  defp render(markers) do
    Map.new(markers, fn {tl, m} ->
      {tl,
       %{
         last_read_id: m.last_read_id,
         version: m.version,
         updated_at: format_dt(m.updated_at)
       }}
    end)
  end

  # The `markers` table is the one schema still on Ecto's default
  # `timestamps()` (naive_datetime), so `updated_at` arrives as a
  # NaiveDateTime — passing it straight to `DateTime.to_iso8601/1`
  # crashed the endpoint. Treat the naive value as UTC (it was written
  # with NaiveDateTime.utc_now/0) and emit a proper `…Z` timestamp.
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_dt(%NaiveDateTime{} = dt),
    do: dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp format_dt(_), do: nil

  # ── inputs ───────────────────────────────────────────────────────────────

  # `timeline[]=home&timeline[]=notifications` — URI.decode_query
  # collapses repeated keys (last wins), so split manually.
  defp extract_timelines(nil), do: []
  defp extract_timelines(""), do: []

  defp extract_timelines(qs) when is_binary(qs) do
    qs
    |> String.split("&", trim: true)
    |> Enum.flat_map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> [{URI.decode_www_form(k), URI.decode_www_form(v)}]
        _ -> []
      end
    end)
    |> Enum.filter(fn {k, _} -> k == "timeline[]" or k == "timeline" end)
    |> Enum.map(fn {_, v} -> v end)
    |> Enum.filter(&(&1 in @timelines))
    |> Enum.uniq()
  end

  # JSON: %{"home" => %{"last_read_id" => "..."}}
  # Form: %{"home[last_read_id]" => "..."}
  defp extract_updates(body) when is_map(body) do
    Enum.flat_map(@timelines, fn tl ->
      cond do
        is_map(body[tl]) and is_binary(body[tl]["last_read_id"]) ->
          [{tl, body[tl]["last_read_id"]}]

        is_binary(body["#{tl}[last_read_id]"]) ->
          [{tl, body["#{tl}[last_read_id]"]}]

        true ->
          []
      end
    end)
  end

  defp extract_updates(_), do: []

  # ── helpers (mirror the shape used in mastodon_push.ex) ──────────────────

  defp with_viewer(req, fun) do
    case req[:assigns][:current_account] do
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
