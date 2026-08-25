# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.DecoFollow do
  use Ecto.Schema
  import Ecto.Changeset

  # 板に入っている、という一行。ローカルの人は `account_id`、
  # 連合越しに Follow してきた相手は `follower_uri` ── 同じ表に
  # 入れておくので、板の Group actor が Follow を受けるようになった
  # とき、中と外が一つの事実に乗る。
  schema "deco_follows" do
    field(:deco_id, :integer)
    field(:account_id, :integer)
    field(:follower_uri, :string)
    field(:state, :string, default: "accepted")

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(follow, attrs) do
    follow
    |> cast(attrs, [:deco_id, :account_id, :follower_uri, :state])
    |> validate_required([:deco_id])
    |> validate_inclusion(:state, ~w(pending accepted))
    |> check_who()
    |> unique_constraint([:deco_id, :account_id])
    |> unique_constraint([:deco_id, :follower_uri])
  end

  # どちらか一方は要る。両方入っている行は、あとで「どちらが本当か」
  # を決められなくなる。
  defp check_who(changeset) do
    case {get_field(changeset, :account_id), get_field(changeset, :follower_uri)} do
      {nil, nil} -> add_error(changeset, :account_id, "か follower_uri が要ります")
      {a, u} when not is_nil(a) and not is_nil(u) -> add_error(changeset, :account_id, "と follower_uri は同時に持てません")
      _ -> changeset
    end
  end
end
