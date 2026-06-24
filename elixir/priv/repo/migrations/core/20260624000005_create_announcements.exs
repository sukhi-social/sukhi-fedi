# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.CreateAnnouncements do
  use Ecto.Migration

  @moduledoc """
  Server announcements: a note the admin pins for everyone on the box
  to see in their client (Mastodon's `/api/v1/announcements`). Local
  only — never federated. A `published` announcement shows to readers
  while it is inside its optional `starts_at`..`ends_at` window; outside
  it, or while unpublished, it is a draft the admin can still edit.

  `announcement_dismissals` carries the per-reader "I've seen this"
  state behind `POST /:id/dismiss` — one row per (announcement, account),
  so `read` is just "does a row exist". No reactions table here: the
  client contract returns `reactions: []` for now (see
  `SukhiApi.Views.MastodonAnnouncement`); reaction storage can land
  later without touching this shape.
  """

  def change do
    create table(:announcements) do
      add :content, :text, null: false, default: ""
      add :published, :boolean, null: false, default: false
      add :all_day, :boolean, null: false, default: false
      add :starts_at, :utc_datetime
      add :ends_at, :utc_datetime
      add :published_at, :utc_datetime
      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at)
    end

    create table(:announcement_dismissals) do
      add :announcement_id, references(:announcements, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    create unique_index(:announcement_dismissals, [:announcement_id, :account_id])
    create index(:announcement_dismissals, [:account_id])
  end
end
