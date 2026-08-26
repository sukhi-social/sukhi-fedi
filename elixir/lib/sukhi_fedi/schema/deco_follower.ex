# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.DecoFollower do
  use Ecto.Schema
  import Ecto.Changeset

  # 板を追っている、よその一人。`manuallyApprovesFollowers` は false
  # なので、受けた時点で通っている ── 待たせる状態を持たない。
  schema "deco_followers" do
    field(:deco_id, :integer)
    field(:follower_uri, :string)
    field(:inbox_url, :string)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(f, attrs) do
    f
    |> cast(attrs, [:deco_id, :follower_uri, :inbox_url])
    |> validate_required([:deco_id, :follower_uri])
    |> unique_constraint([:deco_id, :follower_uri])
  end
end
