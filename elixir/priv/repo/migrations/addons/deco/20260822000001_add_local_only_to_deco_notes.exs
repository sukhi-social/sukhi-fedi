defmodule SukhiFedi.Repo.Migrations.AddLocalOnlyToDecoNotes do
  use Ecto.Migration

  def change do
    # 投稿時に選べる公開範囲(全域/ローカル)。notes.visibility は
    # 触らない(そちらは "public" のまま、既存の可視性ロジックが
    # そのまま通る) ── ここは「連合に出すかどうか」だけの、板固有の
    # 上乗せフラグ。
    alter table(:deco_notes) do
      add(:local_only, :boolean, default: false, null: false)
    end
  end
end
