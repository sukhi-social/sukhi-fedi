defmodule SukhiFedi.Repo.Migrations.AddHasActorToDecos do
  use Ecto.Migration

  def change do
    # 板そのものが、外から見つけられる場所として立っているか ── 表札。
    # 立っていれば `{slug}-deco@domain` で引けて、webfinger にも出る。
    #
    # `local_only` とは別の軸。あちらは「書いたものが、どこまで届くか」で、
    # こちらは「場が、外から見えるか」。うちの中の板でも、書いた人が選べば
    # その一件は外に出る ── 出ていくのは板ではなく、書いた人の投稿だから
    # （投稿は元々その人のアカウントから連合する）。
    #
    # 既定は true ── いままでの板は全部、作られたときに鍵をもらって
    # 引けるようになっている。移行で誰かの表札を下ろさない。
    alter table(:decos) do
      add(:has_actor, :boolean, default: true, null: false)
    end
  end
end
