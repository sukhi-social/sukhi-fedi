# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.PreviewCard do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc "A link preview card (FEP-8967) for a note's first link."

  schema "preview_cards" do
    field :note_id, :integer
    field :url, :string
    field :title, :string, default: ""
    field :description, :string, default: ""
    field :image, :string
    field :type, :string, default: "link"
    field :provider_name, :string, default: ""

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  @fields ~w(note_id url title description image type provider_name)a

  def changeset(card, attrs) do
    card
    |> cast(attrs, @fields)
    |> validate_required([:note_id, :url])
    |> validate_length(:title, max: 500)
    |> validate_length(:description, max: 1000)
  end
end
