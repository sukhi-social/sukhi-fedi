# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.DecoNote do
  use Ecto.Schema
  import Ecto.Changeset

  # 「この note は、この板のもの」という一行。本文も、書いた人も、
  # notes 側にある。
  schema "deco_notes" do
    field(:deco_id, :integer)
    field(:note_id, :integer)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(deco_note, attrs) do
    deco_note
    |> cast(attrs, [:deco_id, :note_id])
    |> validate_required([:deco_id, :note_id])
    |> unique_constraint(:note_id)
  end
end
