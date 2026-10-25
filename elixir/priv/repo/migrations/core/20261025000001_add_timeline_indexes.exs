# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddTimelineIndexes do
  use Ecto.Migration

  @moduledoc """
  Indexes in the order the timelines read, which is `notes.id DESC`
  (`Timelines.apply_paging/2`), not `created_at`:

    * home — `account_id IN (followed…) ORDER BY id DESC LIMIT n` walks
      `(account_id, id DESC)` instead of collecting every note of every
      followed account and sorting them;
    * public (local) — a partial index holding only public local notes,
      already in page order;
    * bubble — public notes of an allow-listed `domain`, in page order;
    * home boosts — `account_id IN (…) ORDER BY created_at DESC`.

  The old `(visibility, created_at)` index orders by the wrong column for
  these reads and is left alone (other queries may use it).
  """

  def change do
    create_if_not_exists index(:notes, [:account_id, "id DESC"], name: :notes_account_id_id_desc_index)

    create_if_not_exists index(:notes, ["id DESC"],
                           name: :notes_public_local_id_desc_index,
                           where: "visibility = 'public' AND domain IS NULL"
                         )

    create_if_not_exists index(:notes, [:domain, "id DESC"],
                           name: :notes_public_domain_id_desc_index,
                           where: "visibility = 'public' AND domain IS NOT NULL"
                         )

    create_if_not_exists index(:boosts, [:account_id, "created_at DESC"],
                           name: :boosts_account_id_created_at_desc_index
                         )
  end
end
