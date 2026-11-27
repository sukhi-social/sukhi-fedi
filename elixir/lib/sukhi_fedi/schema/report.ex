# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Report do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:note_id, to: "notes", on_delete: :nilify, name: "reports_note_id_fkey")

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
