defmodule SukhiFedi.Repo.Migrations.AddI18nToDeco do
  use Ecto.Migration

  def change do
    # 板の名前・説明の、もう一つの言語。`name`/`description` は主言語
    # (必須)のまま ── これは上乗せの、任意の言語ぶんだけ。
    alter table(:decos) do
      add(:name_i18n, :map)
      add(:description_i18n, :map)
    end

    # 投稿は notes に相乗り(単一言語のまま連合する)なので、他言語は
    # notes 側ではなく、こちら(板との結び)に持たせる ── 連合の形を
    # 一切変えずに、natadeco の読み側だけで多言語を足せる。
    alter table(:deco_notes) do
      add(:title_i18n, :map)
      add(:content_i18n, :map)
    end
  end
end
