# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.Feedback do
  @moduledoc "JSON shape of a feedback inbox item (operator view)."

  alias SukhiApi.Views.{Id, Timestamp}

  @spec render(map()) :: map()
  def render(item) do
    %{
      id: Id.encode(item.id),
      body: item.body,
      screen: item.screen,
      lang: item.lang,
      version: item.version,
      account_id: Id.encode(item.account_id),
      handled_at: Timestamp.iso8601(item.handled_at),
      handled_by_id: Id.encode(item.handled_by_id),
      created_at: Timestamp.iso8601(item.created_at)
    }
  end

  @spec render_list([map()]) :: [map()]
  def render_list(items) when is_list(items), do: Enum.map(items, &render/1)
end
