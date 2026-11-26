# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Marker do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's unique indexes, kept by the store
  hosi_unique([:account_id, :timeline], name: "markers_account_id_timeline_index")

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:account_id, to: "accounts", on_delete: :cascade, name: "markers_account_id_fkey")

  schema "markers" do
    belongs_to(:account, SukhiFedi.Schema.Account)
    field(:timeline, :string)
    field(:last_read_id, :string)
    field(:version, :integer, default: 1)
    timestamps()
  end

  @allowed_timelines ~w(home notifications)

  def changeset(marker, attrs) do
    marker
    |> cast(attrs, [:account_id, :timeline, :last_read_id, :version])
    |> validate_required([:account_id, :timeline, :last_read_id])
    |> validate_inclusion(:timeline, @allowed_timelines)
    |> unique_constraint([:account_id, :timeline])
  end
end
