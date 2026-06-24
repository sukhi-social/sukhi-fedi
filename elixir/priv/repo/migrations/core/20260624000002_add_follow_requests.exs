# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddFollowRequests do
  use Ecto.Migration

  @moduledoc """
  Inbound manual follow approval for locked accounts.

  Until now sukhi auto-accepted every inbound Follow, so a locked
  (`manuallyApprovesFollowers`) account's lock did nothing on the
  receiving side. This table is the waiting room: a Follow aimed at a
  locked account lands here as a pending request instead of an accepted
  follow, and stays until the owner authorizes or rejects it.

    * `follow_activity` — the original Follow JSON-LD, kept so we can
      build the eventual `Accept` (whose object is that Follow) without
      re-fetching it.
    * `follower_inbox`  — where the Accept/Reject is delivered.

  On authorize the row becomes a real `follows` row (`accepted`) and we
  deliver the Accept; on reject we deliver a Reject and drop the row.
  """

  def change do
    create table(:follow_requests) do
      add :followee_id, references(:accounts, on_delete: :delete_all), null: false
      add :follower_uri, :string, null: false
      add :follow_activity, :map, null: false
      add :follower_inbox, :string, null: false
      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    # One pending request per (followee, follower); a re-sent Follow reuses it.
    create unique_index(:follow_requests, [:followee_id, :follower_uri])
  end
end
