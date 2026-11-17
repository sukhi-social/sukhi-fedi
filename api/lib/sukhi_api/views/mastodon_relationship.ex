# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.MastodonRelationship do
  @moduledoc """
  Render a Mastodon Relationship (`/api/v1/accounts/relationships`).

  Input shape (from `SukhiFedi.Social.list_relationships/2`):

      %{
        id: 42,                       # target account id (required)
        following: bool,
        followed_by: bool,
        showing_reblogs: bool,
        notifying: bool,
        blocking: bool,
        blocked_by: bool,
        muting: bool,
        muting_notifications: bool,
        requested: bool,
        domain_blocking: bool,
        endorsed: bool,
        note: String,
        group: %{member: bool, role: String | nil}   # optional, see below
      }

  Missing keys default to `false`/`""`.

  `group` is Bonfire's group extension. The key is rendered only when the
  viewer has a membership row with the target (`Social.list_relationships/2`
  leaves it `nil` otherwise), so a Relationship for an ordinary account
  stays exactly Mastodon's.
  """

  alias SukhiApi.Views.Id

  @spec render(map()) :: map()
  def render(rel) when is_map(rel) do
    base = render_base(rel)

    # Bonfire's group extension: `group: {member, role}`, present for a group
    # the viewer has a membership row with and absent for everything else.
    case rel[:group] do
      %{member: member, role: role} -> Map.put(base, :group, %{member: member, role: role})
      _ -> base
    end
  end

  defp render_base(rel) do
    %{
      id: Id.encode(rel.id),
      following: !!rel[:following],
      showing_reblogs: !!Map.get(rel, :showing_reblogs, true),
      notifying: !!rel[:notifying],
      languages: Map.get(rel, :languages, []),
      followed_by: !!rel[:followed_by],
      blocking: !!rel[:blocking],
      blocked_by: !!rel[:blocked_by],
      muting: !!rel[:muting],
      muting_notifications: !!rel[:muting_notifications],
      requested: !!rel[:requested],
      requested_by: !!Map.get(rel, :requested_by, false),
      domain_blocking: !!rel[:domain_blocking],
      endorsed: !!rel[:endorsed],
      note: Map.get(rel, :note) || ""
    }
  end

  @spec render_list([map()]) :: [map()]
  def render_list(rels) when is_list(rels), do: Enum.map(rels, &render/1)
end
