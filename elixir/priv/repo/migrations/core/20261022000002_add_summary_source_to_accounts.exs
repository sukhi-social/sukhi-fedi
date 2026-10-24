# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddSummarySourceToAccounts do
  use Ecto.Migration

  # The bio as its author typed it (Markdown). `summary` keeps the rendered,
  # sanitised HTML that federates and that every client reads; this column is
  # only what the edit box re-opens (Mastodon `source.note`). NULL for remote
  # rows and for local bios written before the column existed.
  def change do
    alter table(:accounts) do
      add :summary_source, :text
    end
  end
end
