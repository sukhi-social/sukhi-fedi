# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.DecoPref do
  use Ecto.Schema
  import Ecto.Changeset

  # その人と、その板の関わりかた。読んだ位置と、知らせかた。
  #
  # 「入る」は無い ── 自分が書いた板は、書いた時点で自分の場所に
  # なっている（宣言ではなく事実）。ここが持つのは、その既定から
  # ずらしたいときの一行だけ。
  schema "deco_prefs" do
    field(:account_id, :integer)
    field(:deco_id, :integer)
    field(:seen_at, :utc_datetime)

    # participating — 既定。自分が書いた話だけ気にかける
    # all           — この板が動いたら気づく（読み専の人はここ）
    # quiet         — 光らない
    field(:notify, :string, default: "participating")
  end

  @notify ~w(participating all quiet)

  @doc "知らせかたの、取りうる値。"
  def notify_kinds, do: @notify

  def changeset(pref, attrs) do
    pref
    |> cast(attrs, [:account_id, :deco_id, :seen_at, :notify])
    # `seen_at` は無くていい ── 知らせかたを決めただけで、まだ読んで
    # いない状態がある。そこを「いま読んだ」で埋めると、光りが消える。
    |> validate_required([:account_id, :deco_id])
    |> validate_inclusion(:notify, @notify)
    |> unique_constraint([:account_id, :deco_id])
  end
end
