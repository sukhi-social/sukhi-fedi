# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.CustomEmojisLocalShortcodeUnique do
  use Ecto.Migration

  @moduledoc """
  One local emoji per shortcode, said by the database.

  `(shortcode, domain)` is unique, but Postgres treats NULLs as distinct, so
  for a local emoji (`domain IS NULL`) that index allows the same shortcode
  any number of times; `CustomEmojis` papered over it by reading before it
  wrote. A partial unique index on `shortcode WHERE domain IS NULL` closes it.

  **This migration deletes nothing.** If local duplicates already exist it
  stops and names them, because which row survives is a data decision (the
  code has always read and updated the lowest id, so that is the usual
  survivor; the rest are stale copies — but check what points at them first).
  Look before deploying:

      SELECT shortcode, array_agg(id ORDER BY id) AS ids
        FROM custom_emojis WHERE domain IS NULL
       GROUP BY shortcode HAVING count(*) > 1;

  Merge or delete the extras by hand, then migrate.
  """

  def up do
    execute("""
    DO $$
    DECLARE
      dupes text;
    BEGIN
      SELECT string_agg(shortcode || ' (ids ' || ids || ')', ', ' ORDER BY shortcode)
        INTO dupes
        FROM (
          SELECT shortcode, string_agg(id::text, ',' ORDER BY id) AS ids
            FROM custom_emojis
           WHERE domain IS NULL
           GROUP BY shortcode
          HAVING count(*) > 1
        ) d;

      IF dupes IS NOT NULL THEN
        RAISE EXCEPTION
          'custom_emojis has duplicate local shortcodes; merge them, then migrate again: %', dupes;
      END IF;
    END
    $$;
    """)

    create unique_index(:custom_emojis, [:shortcode],
             where: "domain IS NULL",
             name: :custom_emojis_local_shortcode_index
           )
  end

  def down do
    drop index(:custom_emojis, [:shortcode], name: :custom_emojis_local_shortcode_index)
  end
end
