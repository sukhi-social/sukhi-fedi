# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddCategoryAndAliasesToCustomEmojis do
  use Ecto.Migration

  def change do
    alter table(:custom_emojis) do
      add :category, :string
      add :aliases, {:array, :string}, null: false, default: []
    end
  end
end
