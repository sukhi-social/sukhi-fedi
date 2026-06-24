# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.StatusHydration do
  @moduledoc """
  Render notes into Mastodon Status JSON with the per-note context that
  has to be batch-fetched from the gateway: the Sukhi reaction chips
  (`reactions_for_notes`), the interaction counts (`counts_for_notes`)
  and the viewer's own favourite / boost / bookmark flags
  (`viewer_flags_many`).

  Every status-returning endpoint should render through here. The view
  itself only shows this context when it's handed in via the render
  context, so any path that calls `MastodonStatus.render/1` bare drops
  it silently — which is how the note page and profile once lost their
  reaction chips, and how the timeline showed every post as
  un-favourited and un-bookmarked even right after you'd favourited it.
  Funnelling the hydration here keeps the timeline, the profile, the
  note page and its thread in step instead of each capability
  re-deriving (and drifting on) the context.
  """

  alias SukhiApi.GatewayRpc
  alias SukhiApi.Views.MastodonStatus

  @doc "Render one note (or nil) with reaction chips from `viewer`'s view."
  @spec one(map() | nil, map() | nil) :: map() | nil
  def one(nil, _viewer), do: nil
  def one(note, viewer), do: [note] |> many(viewer) |> hd()

  @doc "Render a list of notes with reaction chips from `viewer`'s view."
  @spec many([map()], map() | nil) :: [map()]
  def many([], _viewer), do: []

  def many(notes, viewer) when is_list(notes) do
    # Key off `context_key` so a boost wrapper's context (counts, the viewer's
    # flags, reactions) is fetched for the boosted note (its real id), not the
    # synthesized wrapper id.
    note_ids = Enum.map(notes, &MastodonStatus.context_key/1)
    viewer_id = viewer && viewer.id

    counts =
      case GatewayRpc.call(SukhiFedi.Notes, :counts_for_notes, [note_ids]) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    viewer_flags =
      case GatewayRpc.call(SukhiFedi.Notes, :viewer_flags_many, [viewer_id, note_ids]) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    reactions =
      case GatewayRpc.call(SukhiFedi.Notes, :reactions_for_notes, [note_ids, viewer_id]) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    cards =
      case GatewayRpc.call(SukhiFedi.PreviewCards, :for_notes, [note_ids]) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    MastodonStatus.render_list(notes, counts, viewer_flags, reactions, cards)
  end
end
