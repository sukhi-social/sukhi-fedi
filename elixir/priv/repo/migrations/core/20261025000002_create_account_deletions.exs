# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.CreateAccountDeletions do
  use Ecto.Migration

  @moduledoc """
  Closing an account (docs/MUZAI_NO_SHICHISE.md §房舎施).

  `accounts.deleted_at` marks a closed account. The row itself is **kept**
  — its username with it — and that is what makes the handle a permanent
  retirement: the local-username unique index never lets anyone, the
  former owner included, take it again. Everything personal is blanked.

  `account_deletions` is the one-day grace: a request is a row; the owner
  can cancel it until `scheduled_for`; the worker runs it after.
  """

  def change do
    alter table(:accounts) do
      add(:deleted_at, :utc_datetime)
    end

    create table(:account_deletions) do
      add(:account_id, references(:accounts, on_delete: :nothing), null: false)
      add(:requested_at, :utc_datetime, null: false)
      add(:scheduled_for, :utc_datetime, null: false)
      add(:cancelled_at, :utc_datetime)
      add(:started_at, :utc_datetime)
      add(:finished_at, :utc_datetime)
    end

    # One live request per account.
    create(
      unique_index(:account_deletions, [:account_id],
        where: "cancelled_at IS NULL AND finished_at IS NULL",
        name: :account_deletions_live_index
      )
    )

    create(
      index(:account_deletions, [:scheduled_for],
        where: "cancelled_at IS NULL AND finished_at IS NULL"
      )
    )
  end
end
