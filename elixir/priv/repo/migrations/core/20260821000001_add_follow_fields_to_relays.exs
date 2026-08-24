# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddFollowFieldsToRelays do
  use Ecto.Migration

  # A relay subscription is an outbound `Follow` of AS#Public, so undoing
  # it needs the two things the `Undo` must echo: which local actor sent
  # the Follow, and the Follow's activity id. Nullable — a row created
  # before this migration has neither, and unsubscribing it can only drop
  # the row locally.
  def change do
    alter table(:relays) do
      add :follow_actor_uri, :text
      add :follow_activity_id, :text
    end
  end
end
