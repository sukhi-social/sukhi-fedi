# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountRepo.Migrations.KeepAccountsAndAudits do
  @moduledoc false
  # Two rows the database itself keeps:
  #
  #   * `accounts` — never deleted. What hangs off an account (notes, follows,
  #     …) is outside this database, so nothing here could take it along. A
  #     closed account stays, blanked (`SukhiFedi.AccountDeletion`).
  #   * `admin_audits` — append-only: never updated, never deleted.
  #
  # TRUNCATE fires no row trigger; the tests empty the tables with it.
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION refuse_row_change() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '% keeps its rows: % is refused', TG_TABLE_NAME, TG_OP;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER accounts_kept BEFORE DELETE ON accounts
    FOR EACH ROW EXECUTE FUNCTION refuse_row_change()
    """)

    execute("""
    CREATE TRIGGER admin_audits_append_only BEFORE UPDATE OR DELETE ON admin_audits
    FOR EACH ROW EXECUTE FUNCTION refuse_row_change()
    """)
  end

  def down do
    execute("DROP TRIGGER admin_audits_append_only ON admin_audits")
    execute("DROP TRIGGER accounts_kept ON accounts")
    execute("DROP FUNCTION refuse_row_change()")
  end
end
