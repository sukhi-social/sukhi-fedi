# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.MisskeyNoteDraft do
  @moduledoc """
  Render a NoteDraft row into the compose-draft JSON the SPA restores.
  The keys mirror `web/src/lib/compose-draft.ts`'s `ComposeDraft`
  (`text`, `spoiler`, `useSpoiler`, `sensitive`, `visibility`) so the
  client reconciles the server copy against its local one without a
  translation step. `useSpoiler` is derived: a stored spoiler means the
  fold was on.

  `nil` (no draft) renders as `nil`; the capability maps that to 204.
  """

  alias SukhiApi.Views.Timestamp

  def render(nil), do: nil

  def render(draft) do
    spoiler = draft.spoiler || ""

    %{
      text: draft.text || "",
      spoiler: spoiler,
      useSpoiler: spoiler != "",
      sensitive: !!draft.sensitive,
      visibility: draft.visibility,
      updated_at: Timestamp.iso8601(draft.updated_at)
    }
  end
end
