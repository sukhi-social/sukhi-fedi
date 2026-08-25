defmodule SukhiFedi.Repo.Migrations.AddKindToDecos do
  use Ecto.Migration

  def change do
    # 板の読まれかた。
    #
    #   "thread" — 題をつけて一本立てる。返信が付くと上に浮く（bump）。
    #              話題に優しい ── 二日前の話でも、動けば戻ってくる。
    #   "talk"   — 平らに、書かれた順。題は要らない。雑談に優しい。
    #
    # 一つの板に二つの見かたを載せるのではなく、板の性質にした。
    # 同じ列に混ぜると雑談が必ず勝つ（今日 40 件しゃべった話が、二日で
    # 3 返信の話の上にいつも居る）ので、並べるのをやめて部屋を分ける。
    #
    # 既定は "thread" ── いままでの板がそれ。
    alter table(:decos) do
      add(:kind, :string, default: "thread", null: false)
    end
  end
end
