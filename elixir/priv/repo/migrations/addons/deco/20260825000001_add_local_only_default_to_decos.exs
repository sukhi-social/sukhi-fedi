defmodule SukhiFedi.Repo.Migrations.AddLocalOnlyDefaultToDecos do
  use Ecto.Migration

  def change do
    # 板ごとの、公開範囲の既定。`deco_notes.local_only` が一件ごとの
    # 事実で、こちらは「この板は、ふつうどちらで書くか」。
    #
    # 決めるのを板に持たせるのは、外に出すかどうかが書き手の癖ではなく
    # 場の性質だから ── 静かに話す板と、外に届けたい板が、同じサーバに
    # 並んでいていい。書く人は一件ごとに変えられる（既定であって、
    # 錠ではない）。
    #
    # 既定の既定は false（＝外に出る）。いままでの板の振る舞いがそれで、
    # 移行で誰かの板が黙って外に出なくなるほうが困る。
    alter table(:decos) do
      add(:local_only, :boolean, default: false, null: false)
    end
  end
end
