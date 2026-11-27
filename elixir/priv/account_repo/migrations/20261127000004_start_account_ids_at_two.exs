# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountRepo.Migrations.StartAccountIdsAtTwo do
  @moduledoc false
  # Rows in hosigraph point at an account by its id, and hosigraph keeps ids up
  # to 1 for itself: it refuses to write a reference to them.
  use Ecto.Migration

  def up do
    # count 1 as used, without moving a sequence that is already further on
    execute("SELECT setval('accounts_id_seq', (SELECT last_value FROM accounts_id_seq), true)")
    create(constraint(:accounts, :accounts_id_above_reserved, check: "id > 1"))
  end

  def down do
    drop(constraint(:accounts, :accounts_id_above_reserved))
  end
end
