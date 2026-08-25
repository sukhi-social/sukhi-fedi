defmodule SukhiFedi.Repo.Migrations.CreateDecoFollowsAndReads do
  use Ecto.Migration

  def change do
    # 入っている板。IRC の JOIN にあたる ── 一覧のうち、自分の部屋は
    # どれか。
    #
    # `follows` を借りられない: あちらは `follower_uri → followee_id`
    # で、`followee_id` は `accounts.id` を指す。板は accounts に居ない
    # （鍵も decos が自分で持っている）ので、指せる列が無い。
    #
    # ローカルの人(`account_id`)とリモートからの Follow(`follower_uri`)
    # を同じ表に入れておく ── 板の Group actor が Follow を受理する段に
    # なったとき、同じ「入っている」という一つの事実に乗る。中と外で
    # 二つの表を持つと、そこから必ずズレる。
    create_if_not_exists table(:deco_follows) do
      add(:deco_id, references(:decos, on_delete: :delete_all), null: false)
      add(:account_id, references(:accounts, on_delete: :delete_all))
      add(:follower_uri, :string)
      add(:state, :string, default: "accepted", null: false)

      timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
    end

    create_if_not_exists(unique_index(:deco_follows, [:deco_id, :account_id]))
    create_if_not_exists(unique_index(:deco_follows, [:deco_id, :follower_uri]))
    create_if_not_exists(index(:deco_follows, [:account_id]))

    # どこまで読んだか。板ごとに一点。
    #
    # `markers` は使えない: あちらは timeline ごとに `last_read_id` を
    # 一本持つ形で、板は数が増えるし、bump で古い話が浮くと id 一本では
    # 前後が表せない。時刻で持つほうが、板の並びの都合から独立する。
    #
    # 未読は「この板の最後の動き > seen_at」。数は数えない ── 数字は
    # 圧になるし、追う板が増えるほど零に戻らなくなる。
    create_if_not_exists table(:deco_reads) do
      add(:account_id, references(:accounts, on_delete: :delete_all), null: false)
      add(:deco_id, references(:decos, on_delete: :delete_all), null: false)
      add(:seen_at, :utc_datetime, null: false)
    end

    create_if_not_exists(unique_index(:deco_reads, [:account_id, :deco_id]))
  end
end
