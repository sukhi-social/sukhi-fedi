# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddFollowInvites do
  use Ecto.Migration

  @moduledoc """
  Follow invites (FEP-bebd). A locked account can mint an invite code and
  hand the link to someone; a Follow that arrives carrying that code as
  its `instrument` skips the approval queue and is accepted straight away.

  One reusable code per row, dereferenceable at
  `/users/<u>/invites/<code>` as an `InviteCode` object.
  """

  def change do
    create table(:follow_invites) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :code, :string, null: false
      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    create unique_index(:follow_invites, [:code])
    create index(:follow_invites, [:account_id])
  end
end
