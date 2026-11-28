# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.AdminSuspension do
  @moduledoc """
  JSON shapes for the admin screen of the rests other servers have asked of us
  (FEP-f799, docs/DELIVERY_SUSPENSION.md).

  The gateway has already made `summary` safe (remote HTML through the one
  scrubber) and kept only an `https` address as `url`; this module only turns
  what it was given into JSON. Times are ISO 8601.
  """

  @spec render_list([map()]) :: map()
  def render_list(rows), do: %{suspensions: Enum.map(rows, &render/1)}

  @spec render(map()) :: map()
  def render(row) do
    %{
      id: row.id,
      controller: row.controller,
      target_kind: row.target_kind,
      target: row.target,
      revision: row.revision,
      status: row.status,
      published: time(row.published),
      effective_start: time(row.effective_start),
      effective_end: time(row.effective_end),
      in_effect: row.in_effect,
      ignored: row.ignored,
      ignored_at: time(row.ignored_at),
      summary: row.summary,
      url: row.url,
      evidence: evidence(row.evidence),
      held: row.held
    }
  end

  defp evidence(nil), do: nil

  defp evidence(e) do
    %{
      verified_at: time(e.verified_at),
      attempted_at: time(e.attempted_at),
      failure: e.failure
    }
  end

  defp time(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp time(_), do: nil
end
