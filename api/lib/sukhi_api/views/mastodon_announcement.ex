# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.MastodonAnnouncement do
  @moduledoc """
  Render an announcement into Mastodon announcement JSON.

      %{
        id: "3",
        content: "<p>…</p>",
        starts_at: nil,
        ends_at: nil,
        all_day: false,
        published_at: "2026-06-24T…Z",
        updated_at: "2026-06-24T…Z",
        read: false,
        mentions: [], statuses: [], tags: [], emojis: [], reactions: []
      }

  The `read` flag is the reader's dismiss state; the admin list doesn't
  have a reader, so `render/1` (no flag) reports `read: false` and is
  used by `/api/admin/announcements`. The four trailing arrays and
  `reactions` are part of the contract clients expect — we always emit
  them, empty for now, so a client never trips over a missing key.
  """

  alias SukhiApi.Views.Id

  @spec render(map(), boolean()) :: map()
  def render(announcement, read?) do
    %{
      id: Id.encode(announcement.id),
      content: announcement.content || "",
      starts_at: format_dt(announcement.starts_at),
      ends_at: format_dt(announcement.ends_at),
      all_day: !!announcement.all_day,
      published: !!announcement.published,
      published_at: format_dt(announcement.published_at),
      updated_at: format_dt(announcement.updated_at),
      read: read?,
      mentions: [],
      statuses: [],
      tags: [],
      emojis: [],
      reactions: []
    }
  end

  @spec render(map()) :: map()
  def render(announcement), do: render(announcement, false)

  @doc "Render reader-facing `{announcement, read?}` pairs from the context."
  @spec render_pairs([{map(), boolean()}]) :: [map()]
  def render_pairs(pairs) when is_list(pairs) do
    Enum.map(pairs, fn {a, read?} -> render(a, read?) end)
  end

  @doc "Render admin-facing announcement rows (no reader → read: false)."
  @spec render_list([map()]) :: [map()]
  def render_list(list) when is_list(list), do: Enum.map(list, &render/1)

  defp format_dt(nil), do: nil
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
