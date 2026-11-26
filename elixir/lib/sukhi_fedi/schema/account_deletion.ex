# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.AccountDeletion do
  @moduledoc """
  One request to close an account. Live while neither `cancelled_at` nor
  `finished_at` is set. See `SukhiFedi.AccountDeletion`.
  """
  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's unique indexes, kept by the store
  hosi_unique(:account_id,
    name: "account_deletions_live_index",
    where: [null: [:cancelled_at, :finished_at]]
  )

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :none, name: "account_deletions_account_id_fkey")

  schema "account_deletions" do
    field(:account_id, :integer)
    field(:requested_at, :utc_datetime)
    field(:scheduled_for, :utc_datetime)
    field(:cancelled_at, :utc_datetime)
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)
  end
end
