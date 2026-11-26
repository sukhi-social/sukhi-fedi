# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.InstanceBlock do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's unique indexes, kept by the store
  hosi_unique(:domain)

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:created_by_id, to: "accounts", on_delete: :nilify, name: "instance_blocks_created_by_id_fkey")

  schema "instance_blocks" do
    field(:domain, :string)
    field(:severity, :string)
    field(:reason, :string)
    belongs_to(:created_by, SukhiFedi.Schema.Account)
    timestamps()
  end
end
