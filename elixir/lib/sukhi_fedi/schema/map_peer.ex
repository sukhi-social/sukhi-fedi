# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.MapPeer do
  use Ecto.Schema

  schema "map_peers" do
    field :domain, :string
    belongs_to :created_by, SukhiFedi.Schema.Account
    timestamps()
  end
end
