# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Report do
  use Ecto.Schema

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
