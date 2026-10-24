# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.AdminReport do
  @moduledoc """
  JSON shape for an admin dashboard report row. Reporter, target, and
  note are rendered as compact references; full expansion can be added
  when the UI needs it.
  """

  alias SukhiApi.Views.{AdminAccount, Id, Timestamp}

  @spec render(map() | nil) :: map() | nil
  def render(nil), do: nil

  def render(report) do
    %{
      id: Id.encode(report.id),
      status: report.status,
      comment: Map.get(report, :comment),
      reporter: report |> Map.get(:account) |> AdminAccount.render(),
      target: report |> Map.get(:target) |> AdminAccount.render(),
      note: render_note_ref(Map.get(report, :note)),
      resolved_at: Timestamp.iso8601(Map.get(report, :resolved_at)),
      resolved_by: report |> Map.get(:resolved_by) |> AdminAccount.render(),
      created_at: Timestamp.iso8601(Map.get(report, :inserted_at))
    }
  end

  @spec render_list([map()]) :: [map()]
  def render_list(reports) when is_list(reports), do: Enum.map(reports, &render/1)

  defp render_note_ref(nil), do: nil

  defp render_note_ref(note) do
    %{
      id: Id.encode(Map.get(note, :id)),
      content: Map.get(note, :content),
      ap_id: Map.get(note, :ap_id)
    }
  end
end
