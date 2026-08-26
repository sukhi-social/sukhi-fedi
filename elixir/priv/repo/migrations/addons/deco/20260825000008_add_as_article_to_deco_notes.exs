defmodule SukhiFedi.Repo.Migrations.AddAsArticleToDecoNotes do
  use Ecto.Migration

  def change do
    # 長い文章として出すか。書いた人が一件ごとに選ぶ。
    #
    # `Article` は AS2 的には題を持つものの型で、意味の上ではこちらが
    # 正しい。ただし Mastodon は `Article` を CONVERTED_TYPES に入れて
    # いて、本文を一行も出さない ── 題と summary とリンクだけになる。
    # だから既定は `Note` で、これは選んだ人だけのもの。
    #
    # `local_only` と同じ「連合の側にだけ効く上乗せ」なので、notes には
    # 持たせない。
    alter table(:deco_notes) do
      add(:as_article, :boolean, default: false, null: false)
    end
  end
end
