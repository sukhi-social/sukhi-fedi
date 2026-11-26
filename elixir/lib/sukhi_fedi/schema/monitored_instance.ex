# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.MonitoredInstance do
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's unique indexes, kept by the store
  hosi_unique(:domain)

  schema "monitored_instances" do
    field(:domain, :string)
    field(:last_polled_at, :utc_datetime_usec)
    field(:last_version, :string)
    field(:software_name, :string)
    field(:consecutive_failures, :integer, default: 0)
    field(:inactive, :boolean, default: false)

    belongs_to(:actor, SukhiFedi.Schema.Account, foreign_key: :actor_id)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :domain,
      :actor_id,
      :last_polled_at,
      :last_version,
      :software_name,
      :consecutive_failures,
      :inactive
    ])
    |> validate_required([:domain, :actor_id])
    |> validate_format(:domain, ~r/^[a-z0-9.-]+\.[a-z]{2,}$/i)
    |> unique_constraint(:domain)
  end
end
