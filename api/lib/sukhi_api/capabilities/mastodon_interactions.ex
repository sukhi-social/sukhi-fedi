# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonInteractions do
  @moduledoc """
  Status interactions:

      POST /api/v1/statuses/:id/favourite     write:favourites
      POST /api/v1/statuses/:id/unfavourite   write:favourites
      POST /api/v1/statuses/:id/reblog        write:statuses
      POST /api/v1/statuses/:id/unreblog      write:statuses
      POST /api/v1/statuses/:id/bookmark      write:bookmarks
      POST /api/v1/statuses/:id/unbookmark    write:bookmarks
      POST /api/v1/statuses/:id/pin           write:accounts
      POST /api/v1/statuses/:id/unpin         write:accounts

      GET  /api/v1/bookmarks                  read:bookmarks
      GET  /api/v1/favourites                 read:favourites

  Each write returns the updated Status JSON with refreshed counts +
  viewer flags.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.{GatewayRpc, Pagination}
  alias SukhiApi.Views.MastodonStatus

  @impl true
  def routes do
    [
      {:post, "/api/v1/statuses/:id/favourite", &favourite/1, scope: "write:favourites"},
      {:post, "/api/v1/statuses/:id/unfavourite", &unfavourite/1, scope: "write:favourites"},
      {:post, "/api/v1/statuses/:id/reblog", &reblog/1, scope: "write:statuses"},
      {:post, "/api/v1/statuses/:id/unreblog", &unreblog/1, scope: "write:statuses"},
      {:post, "/api/v1/statuses/:id/bookmark", &bookmark/1, scope: "write:bookmarks"},
      {:post, "/api/v1/statuses/:id/unbookmark", &unbookmark/1, scope: "write:bookmarks"},
      {:post, "/api/v1/statuses/:id/pin", &pin/1, scope: "write:accounts"},
      {:post, "/api/v1/statuses/:id/unpin", &unpin/1, scope: "write:accounts"},
      {:get, "/api/v1/bookmarks", &list_bookmarks/1, scope: "read:bookmarks"},
      {:get, "/api/v1/favourites", &list_favourites/1, scope: "read:favourites"}
    ]
  end

  def favourite(req), do: do_action(req, :favourite)
  def unfavourite(req), do: do_action(req, :unfavourite)
  def reblog(req), do: do_action(req, :reblog)
  def unreblog(req), do: do_action(req, :unreblog)
  def bookmark(req), do: do_action(req, :bookmark)
  def unbookmark(req), do: do_action(req, :unbookmark)
  def pin(req), do: do_action(req, :pin)
  def unpin(req), do: do_action(req, :unpin)

  defp do_action(req, fun) do
    %{current_account: viewer} = req[:assigns]
    id = req[:path_params]["id"]

    case viewer do
      nil ->
        ok(403, %{error: "this endpoint requires a user-bound token"})

      %{} = v ->
        case GatewayRpc.run(SukhiFedi.Notes, fun, [v, id]) do
          {:ok, note} ->
            ok(200, render_status_with_context(v, note))

          {:error, :not_found} ->
            ok(404, %{error: "not_found"})

          {:error, :forbidden} ->
            ok(403, %{error: "forbidden"})

          {:unavailable, why} ->
            ok(503, GatewayRpc.unavailable_body(why))

          _ ->
            ok(500, %{error: "internal_error"})
        end
    end
  end

  def list_bookmarks(req) do
    list_with(req, :list_bookmarks, "/api/v1/bookmarks")
  end

  def list_favourites(req) do
    list_with(req, :list_favourites, "/api/v1/favourites")
  end

  defp list_with(req, fun, base_url) do
    %{current_account: viewer} = req[:assigns]
    opts = Pagination.parse_opts(req[:query])

    case viewer do
      nil ->
        ok(403, %{error: "this endpoint requires a user-bound token"})

      %{} = v ->
        case GatewayRpc.run(SukhiFedi.Notes, fun, [v, Map.to_list(opts)]) do
          {:ok, notes} when is_list(notes) ->
            note_ids = Enum.map(notes, & &1.id)

            counts =
              case GatewayRpc.run(SukhiFedi.Notes, :counts_for_notes, [note_ids]) do
                {:ok, m} when is_map(m) -> m
                _ -> %{}
              end

            viewer_flags =
              case GatewayRpc.run(SukhiFedi.Notes, :viewer_flags_many, [v.id, note_ids]) do
                {:ok, m} when is_map(m) -> m
                _ -> %{}
              end

            reactions =
              case GatewayRpc.run(SukhiFedi.Notes, :reactions_for_notes, [note_ids, v.id]) do
                {:ok, m} when is_map(m) -> m
                _ -> %{}
              end

            body = MastodonStatus.render_list(notes, counts, viewer_flags, reactions)
            headers = [{"content-type", "application/json"}]

            headers =
              case Pagination.link_header(base_url, notes, & &1.id, opts) do
                nil -> headers
                link -> [link | headers]
              end

            {:ok, %{status: 200, body: JSON.encode!(body), headers: headers}}

          {:unavailable, why} ->
            ok(503, GatewayRpc.unavailable_body(why))

          _ ->
            ok(500, %{error: "internal_error"})
        end
    end
  end

  defp render_status_with_context(viewer, note) do
    counts =
      case GatewayRpc.run(SukhiFedi.Notes, :counts_for_note, [note.id]) do
        {:ok, %{} = m} -> m
        _ -> %{}
      end

    flags =
      case GatewayRpc.run(SukhiFedi.Notes, :viewer_flags, [viewer.id, note.id]) do
        {:ok, %{} = m} -> m
        _ -> %{}
      end

    reactions =
      case GatewayRpc.run(SukhiFedi.Notes, :reactions_for_notes, [[note.id], viewer.id]) do
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
