# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.AnnouncementDismissal do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's unique indexes, kept by the store
  hosi_unique([:announcement_id, :account_id],
    name: "announcement_dismissals_announcement_id_account_id_index"
  )

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:announcement_id, to: "announcements", on_delete: :cascade, name: "announcement_dismissals_announcement_id_fkey")

  schema "announcement_dismissals" do
    belongs_to(:announcement, SukhiFedi.Schema.Announcement)
    belongs_to(:account, SukhiFedi.Schema.Account)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, [:announcement_id, :account_id])
    |> validate_required([:announcement_id, :account_id])
    |> unique_constraint([:announcement_id, :account_id])
  end
end
