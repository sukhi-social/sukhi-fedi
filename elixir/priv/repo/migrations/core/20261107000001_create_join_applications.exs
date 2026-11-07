# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.CreateJoinApplications do
  use Ecto.Migration

  @moduledoc """
  Applications to join (docs/JOIN.md): what someone writes when they ask
  to be welcomed, instead of walking in with a code.

  Three keys, each for one job, each stored only as a hash:

    * `receipt` — the number in the receipt mail. Not a secret; it lets
      a person match the mail to the page.
    * `claim_hash` — what the *browser* that applied holds (a cookie), so
      "yes, I got the mail" can only come from where the application was
      written.
    * `edit_hash` — set only after that "yes"; the link mailed then.

  An application nobody confirmed is deleted after three hours, so a
  mistyped address never keeps someone else's words around.
  """

  def change do
    create table(:join_applications) do
      add(:receipt, :string, size: 16, null: false)
      add(:email, :string, size: 254, null: false)
      add(:call_name, :string, size: 80)
      add(:found, :text)
      add(:hope, :text)
      add(:lang, :string, size: 8)
      add(:check_on, :date)
      add(:claim_hash, :string, size: 64, null: false)
      add(:edit_hash, :string, size: 64)
      add(:confirmed_at, :utc_datetime)
      timestamps(type: :utc_datetime, inserted_at: :created_at)
    end

    create(unique_index(:join_applications, [:receipt]))
    create(unique_index(:join_applications, [:claim_hash]))
    create(unique_index(:join_applications, [:edit_hash]))
    create(index(:join_applications, [:confirmed_at, :created_at]))
  end
end
