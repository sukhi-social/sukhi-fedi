# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddPreviewCards do
  use Ecto.Migration

  @moduledoc """
  Link preview cards (FEP-8967): one card per note, generated from the
  first link in the body. Stored separately so a slow or failed fetch
  never blocks posting — the note lands first, the card fills in (or
  doesn't) from a background job.
  """

  def change do
    create table(:preview_cards) do
      add :note_id, references(:notes, on_delete: :delete_all), null: false
      add :url, :string, null: false
      add :title, :string, null: false, default: ""
      add :description, :text, null: false, default: ""
      add :image, :string
      add :type, :string, null: false, default: "link"
      add :provider_name, :string, null: false, default: ""
      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    create unique_index(:preview_cards, [:note_id])
  end
end
