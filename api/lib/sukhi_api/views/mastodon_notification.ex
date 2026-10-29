# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.MastodonNotification do
  @moduledoc """
  Render a Notification row into Mastodon notification JSON.

  Mastodon shape:

      %{
        id: "12345",
        type: "favourite" | "reblog" | "follow" | "mention" | "status"
              | "follow_request" | "poll" | "update",
        created_at: "2026-05-19T06:35:00Z",
        account: <Account>,
        status: <Status> | nil
      }

  With the viewer's grouping on, a row that stands for several carries
  `group: %{accounts: [Account]}` (all of them, newest first).

  `:account` is the actor that caused the notification (= the
  `from_account` association). `:status` is the related Note for
  type ∈ {favourite, reblog, mention, status, poll, update}; `nil`
  for plain follow / follow_request.
  """

  alias SukhiApi.Views.{Id, MastodonAccount, MastodonStatus, Timestamp}

  @spec render(map() | nil) :: map() | nil
  def render(nil), do: nil

  def render(notif) do
    base = %{
      id: Id.encode(notif.id),
      type: notif.type,
      created_at: Timestamp.iso8601(Map.get(notif, :created_at)),
      account: account_view(Map.get(notif, :from_account)),
      status: status_view(Map.get(notif, :note))
    }

    # sukhi's own: only when the viewer has grouping on and this row stands
    # for several. `accounts` is every member, newest first (the first is
    # `account`).
    case Map.get(notif, :group) do
      [_, _ | _] = members -> Map.put(base, :group, %{accounts: Enum.map(members, &account_view/1)})
      _ -> base
    end
  end

  @spec render_list([map()]) :: [map()]
  def render_list(notifs) when is_list(notifs), do: Enum.map(notifs, &render/1)

  # Associations survive the gateway RPC hop as plain maps; an
  # unloaded association arrives as a struct named under
  # Ecto.Association.NotLoaded, which we can't reference here
  # (no Ecto dep), but its `__struct__` shape is enough to detect.
  defp account_view(nil), do: nil
  defp account_view(%{username: _} = account), do: MastodonAccount.render(account, %{})
  defp account_view(_), do: nil

  defp status_view(nil), do: nil
  defp status_view(%{id: _, content: _} = note), do: MastodonStatus.render(note, %{})
  defp status_view(_), do: nil
end
