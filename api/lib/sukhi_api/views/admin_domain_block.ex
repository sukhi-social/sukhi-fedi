# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.AdminDomainBlock do
  @moduledoc """
  JSON shape for an `InstanceBlock` row surfaced through the admin API.
  """

  alias SukhiApi.Views.{Id, Timestamp}

  @spec render(map() | nil) :: map() | nil
  def render(nil), do: nil

  def render(block) do
    %{
      id: Id.encode(block.id),
      domain: Map.get(block, :domain),
      severity: Map.get(block, :severity),
      reason: Map.get(block, :reason),
      created_by_id: Id.encode(Map.get(block, :created_by_id)),
      created_at: Timestamp.iso8601(Map.get(block, :inserted_at))
    }
  end

  @spec render_list([map()]) :: [map()]
  def render_list(blocks) when is_list(blocks), do: Enum.map(blocks, &render/1)
end
