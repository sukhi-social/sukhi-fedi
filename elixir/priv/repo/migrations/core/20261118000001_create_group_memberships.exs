# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.CreateGroupMemberships do
  use Ecto.Migration

  @moduledoc """
  Who has asked to join which remote group, and whether the group said yes.

  `follows` says "this person reads that actor"; a membership says "this
  person is *in* that group" (Bonfire's groups keep the two apart: members
  may post, followers only read). The member side is a bare `member_uri`
  like `follows.follower_uri`, so the same rows work whether the member is
  local or, one day, remote.
  """

  def change do
    create table(:group_memberships) do
      add :member_uri, :text, null: false
      add :group_id, references(:accounts), null: false
      add :state, :text, null: false, default: "pending"
      add :created_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:group_memberships, [:member_uri, :group_id])
    create index(:group_memberships, [:group_id])
  end
end
