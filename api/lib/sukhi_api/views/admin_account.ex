# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.AdminAccount do
  @moduledoc """
  Admin-only account JSON. Extends the public `MastodonAccount` view
  with fields only moderators should see: `is_admin`, `is_bot`,
  `suspended_at`, `suspended_by_id`, and `suspension_reason`.
  """

  alias SukhiApi.Views.{Id, MastodonAccount, Timestamp}

  @spec render(map() | nil) :: map() | nil
  def render(nil), do: nil

  def render(account) do
    base = MastodonAccount.render(account, %{})

    Map.merge(base, %{
      is_admin: Map.get(account, :is_admin, false) || false,
      is_bot: Map.get(account, :is_bot, false) || false,
      suspended: not is_nil(Map.get(account, :suspended_at)),
      suspended_at: Timestamp.iso8601(Map.get(account, :suspended_at)),
      suspended_by_id: Id.encode(Map.get(account, :suspended_by_id)),
      suspension_reason: Map.get(account, :suspension_reason)
    })
  end

  @spec render_list([map()]) :: [map()]
  def render_list(accounts) when is_list(accounts), do: Enum.map(accounts, &render/1)
end
