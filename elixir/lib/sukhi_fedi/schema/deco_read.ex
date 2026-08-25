# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.DecoRead do
  use Ecto.Schema
  import Ecto.Changeset

  # 「この板は、ここまで見た」。板ごとに一点、時刻で持つ。
  # 未読は「板の最後の動き > seen_at」── 数は数えない。
  schema "deco_reads" do
    field(:account_id, :integer)
    field(:deco_id, :integer)
    field(:seen_at, :utc_datetime)
  end

  def changeset(read, attrs) do
    read
    |> cast(attrs, [:account_id, :deco_id, :seen_at])
    |> validate_required([:account_id, :deco_id, :seen_at])
    |> unique_constraint([:account_id, :deco_id])
  end
end
