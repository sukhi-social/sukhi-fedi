# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.BubbleInstance do
  use Ecto.Schema
  use Ecto.Hosi.Schema

  # the catalog's unique indexes, kept by the store
  hosi_unique(:domain)

  schema "bubble_instances" do
    field(:domain, :string)
    belongs_to(:created_by, SukhiFedi.Schema.Account)
    timestamps()
  end
end
