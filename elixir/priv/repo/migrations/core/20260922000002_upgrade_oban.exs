# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.UpgradeOban do
  use Ecto.Migration

  # Oban versions its own schema, but the migration that created it
  # (`20260420000006_add_oban`) ran `Oban.Migrations.up()` once and is
  # marked applied — so every Oban upgrade since then silently left the
  # DB behind. The running Oban now expects `suspended` in
  # `oban_job_state`: its unique-job check passes that state as a query
  # parameter, and a value missing from the enum fails the whole insert
  # with `invalid input value for enum oban_job_state: "suspended"`.
  #
  # Re-running `up/0` applies whatever versions are pending, idempotently
  # (it reads the current version from the table comment). v14 adds the
  # `suspended` value; later versions ride along.
  def up, do: Oban.Migrations.up()

  # 13 was the schema before `suspended`. Postgres can't drop an enum
  # value, so v14's down just folds `suspended` rows back to `scheduled`.
  def down, do: Oban.Migrations.down(version: 13)
end
