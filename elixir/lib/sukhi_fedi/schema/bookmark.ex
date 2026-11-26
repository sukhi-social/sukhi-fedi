# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Bookmark do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  # Private per-account note save: local-only, never federated, idempotent.
  # Backs Mastodon bookmarks and Misskey favourites (`/i/favorites`) alike —
  # the storage carries no protocol-specific meaning, only the view layer does.
  # the catalog's unique indexes, kept by the store
  hosi_unique([:account_id, :note_id], name: "bookmarks_account_id_note_id_index")

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :cascade, name: "bookmarks_account_id_fkey")
  hosi_ref(:note_id, to: "notes", on_delete: :cascade, name: "bookmarks_note_id_fkey")

  schema "bookmarks" do
    belongs_to(:account, SukhiFedi.Schema.Account)
    belongs_to(:note, SukhiFedi.Schema.Note)
    timestamps()
  end
end
