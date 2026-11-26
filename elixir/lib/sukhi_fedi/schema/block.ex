# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Block do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's unique indexes, kept by the store
  hosi_unique([:account_id, :target_id], name: "blocks_account_id_target_id_index")

  schema "blocks" do
    belongs_to(:account, SukhiFedi.Schema.Account)
    belongs_to(:target, SukhiFedi.Schema.Account)
    timestamps()
  end
end
