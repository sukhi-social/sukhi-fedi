# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Report do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :nilify, name: "reports_account_id_fkey")
  hosi_ref(:note_id, to: "notes", on_delete: :nilify, name: "reports_note_id_fkey")
  hosi_ref(:resolved_by_id, to: "accounts", on_delete: :nilify, name: "reports_resolved_by_id_fkey")
  hosi_ref(:target_id, to: "accounts", on_delete: :cascade, name: "reports_target_id_fkey")

  schema "reports" do
    belongs_to(:account, SukhiFedi.Schema.Account)
    belongs_to(:target, SukhiFedi.Schema.Account)
    belongs_to(:note, SukhiFedi.Schema.Note)
    belongs_to(:resolved_by, SukhiFedi.Schema.Account)
    field(:comment, :string)
    field(:status, :string)
    field(:resolved_at, :utc_datetime)
    timestamps()
  end
end
