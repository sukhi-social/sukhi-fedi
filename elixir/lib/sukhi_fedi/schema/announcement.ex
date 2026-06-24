# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Announcement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "announcements" do
    field :content, :string
    field :published, :boolean, default: false
    field :all_day, :boolean, default: false
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :published_at, :utc_datetime

    has_many :dismissals, SukhiFedi.Schema.AnnouncementDismissal

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: :updated_at)
  end

  def changeset(announcement, attrs) do
    announcement
    |> cast(attrs, [:content, :published, :all_day, :starts_at, :ends_at, :published_at])
    |> validate_required([:content])
    |> validate_length(:content, min: 1, max: 5000)
  end
end
