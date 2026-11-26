# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.NodeinfoSnapshot do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_ref(:monitored_instance_id, to: "monitored_instances", on_delete: :cascade, name: "nodeinfo_snapshots_monitored_instance_id_fkey")

  schema "nodeinfo_snapshots" do
    field(:polled_at, :utc_datetime_usec)
    field(:version, :string)
    field(:software_name, :string)
    field(:raw, :map)

    belongs_to(:monitored_instance, SukhiFedi.Schema.MonitoredInstance)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:monitored_instance_id, :polled_at, :version, :software_name, :raw])
    |> validate_required([:monitored_instance_id, :polled_at])
  end
end
