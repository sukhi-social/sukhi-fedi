# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.MaintenanceRun do
  @moduledoc """
  One run of a `SukhiFedi.Maintenance.*` script and how far it has got.
  Written by `SukhiFedi.Maintenance.Progress`, read by `/admin`.
  """
  use Ecto.Schema

  schema "maintenance_runs" do
    field(:name, :string)
    field(:mode, :string)
    field(:state, :string, default: "running")
    field(:stage, :string)
    field(:total, :integer, default: 0)
    field(:done, :integer, default: 0)
    field(:failed, :integer, default: 0)
    field(:last_error, :string)
    field(:summary, :map, default: %{})
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)
    field(:updated_at, :utc_datetime)
  end
end
