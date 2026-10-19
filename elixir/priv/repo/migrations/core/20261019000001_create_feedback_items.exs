# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.CreateFeedbackItems do
  use Ecto.Migration

  @moduledoc """
  The feedback inbox (docs/FEEDBACK.md): what people tell the operator
  from inside the app. Deliberately thin — the text, which screen and
  language it was written on, the app version, and *at most* the account
  that sent it. No IP address, no user agent, no session.

  `account_id` is `nilify_all`: when someone deletes their account, what
  they said stays for the operator but no longer points at them.
  """

  def change do
    create table(:feedback_items) do
      add :body, :text, null: false
      add :screen, :string, size: 64
      add :lang, :string, size: 16
      add :version, :string, size: 64
      add :account_id, references(:accounts, on_delete: :nilify_all)
      add :handled_at, :utc_datetime
      add :handled_by_id, references(:accounts, on_delete: :nilify_all)
      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    create index(:feedback_items, [:handled_at])
  end
end
