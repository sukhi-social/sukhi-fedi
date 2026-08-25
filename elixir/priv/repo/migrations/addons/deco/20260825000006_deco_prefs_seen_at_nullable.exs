defmodule SukhiFedi.Repo.Migrations.DecoPrefsSeenAtNullable do
  use Ecto.Migration

  def change do
    # 「知らせかたは決めたが、まだ読んでいない」は実在する状態。
    #
    # NOT NULL のままだと、知らせかたを変えるだけで行が生まれるときに
    # `seen_at` へ何かを書かねばならず、それが「いま」だと**設定した
    # 瞬間に読んだことになる** ── 読んでいない板を「気にかける」に
    # したのに、光りが消えてしまう。
    alter table(:deco_prefs) do
      modify(:seen_at, :utc_datetime, null: true)
    end
  end
end
