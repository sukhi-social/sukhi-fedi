# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.CustomEmoji do
  use Ecto.Schema
  import Ecto.Changeset

  schema "custom_emojis" do
    field :shortcode, :string
    field :domain, :string
    field :image_url, :string
    field :static_url, :string
    field :category, :string
    field :aliases, {:array, :string}, default: []
    field :visible_in_picker, :boolean, default: true
    field :last_fetched_at, :utc_datetime

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(emoji, attrs) do
    emoji
    |> cast(attrs, [
      :shortcode,
      :domain,
      :image_url,
      :static_url,
      :category,
      :aliases,
      :visible_in_picker,
      :last_fetched_at
    ])
    |> validate_required([:shortcode, :image_url])
    |> unique_constraint([:shortcode, :domain], name: :custom_emojis_shortcode_domain_index)
  end
end
