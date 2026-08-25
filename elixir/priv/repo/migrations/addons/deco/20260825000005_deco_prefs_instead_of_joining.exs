defmodule SukhiFedi.Repo.Migrations.DecoPrefsInsteadOfJoining do
  use Ecto.Migration

  def up do
    # 「入る」をやめる。
    #
    # IRC の JOIN から借りた形だったが、IRC の JOIN は「入らないと見えない」
    # ことに重みがあった。natadeco は読むのを誰にでも開いてあるので、その
    # 重みが最初から無い ── 残っていたのは「気づきたい」という表明だけで、
    # それを押させる必要は無かった。しかも一覧のボタンが「入る」なのは、
    # サイトへのログイン（nav.signIn）と同じ言葉で、同じ画面に並んでいた。
    #
    # 代わりに Zulip の形を借りる: 宣言させず、**参加が購読になる**。
    # 自分が書いた板は自分の場所で、それ以外をどう扱うかは板の中の
    # 詳細設定で決める。
    drop_if_exists(table(:deco_follows))

    # `deco_reads` は「どこまで読んだか」だけの表だったが、これからは
    # 「その人と、その板の関わりかた」を持つ ── 読んだ位置と、知らせかた。
    rename(table(:deco_reads), to: table(:deco_prefs))

    alter table(:deco_prefs) do
      # participating — 既定。自分が書いた話だけ気にかける
      # all           — この板が動いたら気づく（読み専の人はここ）
      # quiet         — 光らない
      add(:notify, :string, default: "participating", null: false)
    end
  end

  def down do
    alter table(:deco_prefs) do
      remove(:notify)
    end

    rename(table(:deco_prefs), to: table(:deco_reads))

    create_if_not_exists table(:deco_follows) do
      add(:deco_id, references(:decos, on_delete: :delete_all), null: false)
      add(:account_id, references(:accounts, on_delete: :delete_all))
      add(:follower_uri, :string)
      add(:state, :string, default: "accepted", null: false)

      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end
  end
end
