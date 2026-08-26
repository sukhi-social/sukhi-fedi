defmodule SukhiFedi.Repo.Migrations.CreateDecoFollowers do
  use Ecto.Migration

  def change do
    # 板を追っている、よそのアカウント。
    #
    # `follows` は借りられない ── あちらの `followee_id` は `accounts.id`
    # で、板は accounts に居ない（鍵も decos が自分で持っている）。
    #
    # 一度 `deco_follows` という名で、ローカルの人の「入る」と一緒に
    # 作ったが、「入る」をやめたときに落とした。使う人が居ない表を
    # 「あとで要るから」で持ち続けないため。いま本当に要るので、その
    # ときに要る形で作り直す ── ローカル用の列は無い。ここに載るのは
    # 外から追ってきた相手だけで、うちの人は板に書けばそれが席になる。
    create_if_not_exists table(:deco_followers) do
      add(:deco_id, references(:decos, on_delete: :delete_all), null: false)
      add(:follower_uri, :string, null: false)
      # Announce を配る先。actor を引き直さずに済むよう、受けたときに
      # 控えておく。
      add(:inbox_url, :string)

      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    create_if_not_exists(unique_index(:deco_followers, [:deco_id, :follower_uri]))
  end
end
