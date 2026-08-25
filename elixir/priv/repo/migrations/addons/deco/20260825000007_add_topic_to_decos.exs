defmodule SukhiFedi.Repo.Migrations.AddTopicToDecos do
  use Ecto.Migration

  def change do
    # 「いま話していること」。板が持つ、書き換えられる一行。
    #
    # IRC の /topic から。題を一件ずつに背負わせる代わりに、場のほうが
    # 一本持つ ── 話が流れたら、居る人の誰かが書き換える。話す板に題を
    # 要らなくしたぶん、一覧で見分ける手がかりはここが持つ。
    #
    # 誰が・いつ を一緒に持つのは、それが抑止だから。板の顔になる一行を
    # 黙って書き換えられる形にはしない ──「書いた人は隠さない」と同じ。
    alter table(:decos) do
      add(:topic, :string)
      add(:topic_by_id, references(:accounts, on_delete: :nilify_all))
      add(:topic_at, :utc_datetime)
    end
  end
end
