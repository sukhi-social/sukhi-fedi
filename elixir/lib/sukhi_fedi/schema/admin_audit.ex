# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.AdminAudit do
  @moduledoc """
  One row per admin / moderation action — the append-only audit trail.
  Write-only from the app's side (insert via `changeset/1`); never updated or
  deleted (`SukhiFedi.Datalevin.Writer` refuses both).

  Keep it minimal: the action, who did it, the subject, an optional reason,
  and small structured `metadata` (severity, report id, role flag) — never
  post content.
  """
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's foreign keys (ON DELETE) and write rules, kept by the adapter
  hosi_append_only()

  schema "admin_audits" do
    field(:action, :string)
    field(:admin_account_id, :integer)
    field(:target_account_id, :integer)
    field(:target_domain, :string)
    field(:reason, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @fields [:action, :admin_account_id, :target_account_id, :target_domain, :reason, :metadata]

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required([:action])
  end
end
