# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.AnnouncementDismissal do
  use Ecto.Schema
  import Ecto.Changeset

  schema "announcement_dismissals" do
    belongs_to :announcement, SukhiFedi.Schema.Announcement
    belongs_to :account, SukhiFedi.Schema.Account

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, [:announcement_id, :account_id])
    |> validate_required([:announcement_id, :account_id])
    |> unique_constraint([:announcement_id, :account_id])
  end
end
