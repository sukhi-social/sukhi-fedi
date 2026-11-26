# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.NoteCleanupLedger do
  @moduledoc """
  One row per note hard-deleted by self-cleanup — the "生成と削除のDB". It keeps
  the note's birth (`note_created_at`) and its deletion (`deleted_at`) side by
  side, plus who and why, so the record of a cleanup survives even though the
  note row itself is gone. Append-only from the app: insert via `changeset/1`,
  never updated.
  """
  use Ecto.Schema
  use Ecto.Hosi.Schema
  import Ecto.Changeset

  # the catalog's unique indexes, kept by the store
  hosi_unique(:note_id)

  schema "note_cleanup_ledger" do
    field(:account_id, :integer)
    field(:note_id, :integer)
    field(:note_created_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)
    field(:reason, :string)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @fields [:account_id, :note_id, :note_created_at, :deleted_at, :reason]

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required([:account_id, :note_id, :note_created_at, :deleted_at])
    |> unique_constraint(:note_id)
  end
end
