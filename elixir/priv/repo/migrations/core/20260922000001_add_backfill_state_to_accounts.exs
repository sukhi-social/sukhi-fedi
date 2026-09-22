# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Repo.Migrations.AddBackfillStateToAccounts do
  use Ecto.Migration

  # こちらから follow した remote の過去投稿 backfill（outbox を signed
  # fetch で辿る）の進行状態。`accounts` に置くのは、backfill の単位が
  # 「その影の row の outbox」で、follow の本数ではなく相手の数だから。
  #
  #   nil       ── まだ試していない（boot の pending が拾う）
  #   "pending" ── enqueue 済み、順番待ち
  #   "running" ── worker が取得中
  #   "done"    ── 引けた（`backfill_mirrored` 件を notes に取り込んだ）
  #   "failed"  ── 引けなかった（`backfill_error` に理由）
  #
  # `RemoteAccounts.upsert_from_actor_json/1` はこの 4 列を cast しないので、
  # actor の再取得で進行状態が巻き戻ることはない。
  def change do
    alter table(:accounts) do
      add(:backfill_state, :text)
      add(:backfill_attempted_at, :utc_datetime)
      add(:backfill_mirrored, :integer, null: false, default: 0)
      add(:backfill_error, :text)
    end

    # boot 時に「未着手 / 失敗」だけを引く。partial index で hot set を小さく。
    create(
      index(:accounts, [:backfill_state],
        where: "backfill_state IS NULL OR backfill_state = 'failed'"
      )
    )
  end
end
