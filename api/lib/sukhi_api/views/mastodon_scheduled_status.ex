# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.MastodonScheduledStatus do
  @moduledoc """
  Render a ScheduledStatus row into Mastodon scheduled-status JSON.

      %{
        id: "12",
        scheduled_at: "2026-07-01T09:00:00Z",
        params: %{text:, visibility:, media_ids:, sensitive:, spoiler_text:, in_reply_to_id:},
        media_attachments: []
      }

  `params` echoes the author's create attrs (stored verbatim as string
  keys). `media_attachments` is left empty — the ids ride in `params`,
  and the composer needs no hydrated attachments to confirm a schedule.
  """

  alias SukhiApi.Views.{Id, Timestamp}

  def render(nil), do: nil

  def render(scheduled) do
    p = scheduled.params || %{}

    %{
      id: Id.encode(scheduled.id),
      scheduled_at: Timestamp.iso8601(scheduled.scheduled_at),
      params: %{
        text: p["status"],
        visibility: p["visibility"],
        media_ids: p["media_ids"] || [],
        sensitive: !!p["sensitive"],
        spoiler_text: p["spoiler_text"],
        in_reply_to_id: p["in_reply_to_id"]
      },
      media_attachments: []
    }
  end

  def render_list(list) when is_list(list), do: Enum.map(list, &render/1)
end
