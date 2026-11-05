# sukhi-fedi バックアップ — off-host / restic / B2

単一ホストの sukhi-fedi に「壊れても戻せる」を入れるための、host systemd ベースの
バックアップ一式。**いまは dormant**(ファイルはコミット済みだが、まだ動いていない)。
蛇口をひねる = restic を入れて B2 を発行し、`backup.env` を置いて timer を有効化する。

> このディレクトリのスクリプトは Kamal の外で動く。Kamal は app コンテナを回すだけで、
> バックアップは「ホストの仕事」(postgres / rustfs のボリュームから読み、off-host に書き、
> gateway が unhealthy でも `kamal deploy` の最中でも走る)。だから systemd timer。

## 二軸のリカバリ(取り違えないこと)

| | 何をする | いつ | データ損失 | 道具 |
|---|---|---|---|---|
| **外科的訂正** | 特定の行/列だけ直す | 「間違って入った」 | 無し | `docs/data-correction.ja.md` の maintenance 道具 |
| **全DB巻き戻し** | DB 全体を過去の一点へ | ホスト死亡・DB破損 | その時点以降の良い変更も失う | このバックアップ(restore / PITR) |

「間違って入ったものを直す」のはほぼ **外科的訂正**(`RebuildFromArchive` 等、既に実装済み)。
このバックアップが守るのは「全部が消えた／DB が起動しない」級の大災害。両方いる ──
外科的訂正のためにも、その素材(rustfs の `inbound`/`media`)の off-host コピーが要る。

## 何を取るか

restic スナップショット 1 本に:

- **Postgres** の論理ダンプ(`pg_dump -Fc`、稼働中コンテナ経由でバージョン一致、単一テーブル
  選択 restore 可)
- **rustfs データ全体**(`media` + `inbound` + `outbound` バケット ── 受信/送信の原本アーカイブ)
- **コンテナログ**(`/var/lib/docker/containers/*/*-json.log*`、host loss を越えてログを残す)

restic 一本(単一 Go バイナリ・暗号化・dedup・`restic check` で復元可能性検証)に集約。
バックエンドは Backblaze B2(S3 互換・最安)。圧縮は restic 任せ(`--compression max`)。

## 有効化(蛇口をひねる)

```sh
# 0) restic を入れる(Rocky なら dnf、無ければ公式バイナリ)
sudo dnf install -y restic   # or: download from https://github.com/restic/restic/releases

# 1) B2 バケットとアプリキーを作る
#    - 非公開バケットを 1 つ
#    - そのバケットに絞ったアプリキー。可能なら "no delete"(forget --prune 封じ)、
#      バケットの Object Lock / versioning も有効に
#    - RESTIC_REPOSITORY = s3:s3.<region>.backblazeb2.com/<bucket>

# 2) backup.env を置く
sudo mkdir -p /etc/sukhi-fedi
sudo cp infra/backup/backup.env.example /etc/sukhi-fedi/backup.env
sudo chmod 600 /etc/sukhi-fedi/backup.env
sudo $EDITOR /etc/sukhi-fedi/backup.env     # B2 / restic / postgres を埋める

# 3) スクリプトを置く
sudo cp infra/backup/sukhi-backup.sh infra/backup/sukhi-backup-verify.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/sukhi-backup.sh /usr/local/bin/sukhi-backup-verify.sh

# 4) 一度手で通す(repo init + 初回バックアップ)
sudo --preserve-env=PATH env $(grep -v '^#' /etc/sukhi-fedi/backup.env | xargs) /usr/local/bin/sukhi-backup.sh

# 5) timer を入れて有効化
sudo cp infra/backup/sukhi-backup*.service infra/backup/sukhi-backup*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sukhi-backup.timer sukhi-backup-verify.timer
systemctl list-timers | grep sukhi
```

`sukhi-backup.timer` は毎日 03:17 UTC、`sukhi-backup-verify.timer` は日曜 04:30 UTC。

## 監視(静かに止まったのに気づく)

`backup.env` の `HEALTHCHECK_URL` / `VERIFY_HEALTHCHECK_URL` に
Healthchecks.io / Uptime Kuma の push URL を入れる。スクリプトは **成功時だけ** ping する
ので、ping が来ない = アラート。二つ分けることで「バックアップが止まった」と
「動いてるが復元検証に失敗」を区別できる。ホストが完全に死んでも、ホスト内アラートと違って
気づける。`set -euo pipefail` なので途中失敗は成功 ping に届かない。

アプリ側にも軽い健全性チェックがある(別物・常時稼働):
`SukhiFedi.Maintenance.ArchiveIntegrity`(毎日 03:30、Oban cron)が `inbound_events` の
件数と最新原本の S3 HEAD を見て、ドリフトを WARNING で出す。

## 復元 runbook

### 1) Postgres(全DB巻き戻し / DR)

```sh
# B2 から最新ダンプだけ取り出す
restic restore latest --include '*.dump' --target /tmp/restore
dump="$(find /tmp/restore -name '*.dump' | head -1)"

# 稼働中の postgres コンテナへ流し込む(--clean で作り直し)
docker cp "$dump" sukhi-fedi-postgres:/tmp/restore.dump
docker exec -e PGPASSWORD=<pass> sukhi-fedi-postgres \
  pg_restore -U sukhi -d sukhi_fedi --clean --if-exists --no-owner /tmp/restore.dump
kamal accessory reboot gateway
bin/sukhi_fedi eval "SukhiFedi.Release.migrate()"

# ダンプ時刻〜現在の隙間を受信原本アーカイブから埋める
bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.RebuildFromArchive.run(:execute)'
```

### 2) rustfs(media + inbound + outbound)

```sh
restic restore latest --include '*/sukhi-fedi-rustfs/data/*' --target /
sudo chown -R 10001:10001 ~/sukhi-fedi-rustfs/data    # rustfs の UID(deploy.yml 参照)
kamal accessory restart rustfs
```

### 3) 外科的訂正(主目的・restore 不要)

「間違って入った」を直すのはこっち。手順は [`docs/data-correction.ja.md`](../../docs/data-correction.ja.md)。
dry-run を必ず先に:

```sh
bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.RebuildFromArchive.run(:dry_run)'
bin/sukhi_fedi rpc 'SukhiFedi.Maintenance.RebuildFromArchive.run(:execute)'
```

## 検証(untested backup は演劇)

`sukhi-backup-verify.sh`(週次)が:

1. `restic check`(構造)。`DEEP=1` で `--read-data-subset=5%`(実 blob 再読、bit-rot 検知)。
2. 最新ダンプを **使い捨て postgres コンテナ** に `pg_restore` して `notes` /
   `inbound_events` の件数を assert、破棄。「復元できないダンプ」をここで見つける。
3. 成功で verify 用 healthcheck に ping。

手で一度通すなら:

```sh
sudo DEEP=1 env $(grep -v '^#' /etc/sukhi-fedi/backup.env | xargs) /usr/local/bin/sukhi-backup-verify.sh
```

## A4: PITR(任意秒に巻き戻し)── 上位互換・dormant

夜次ダンプは総ホスト喪失で最大 ~24h の自作 outbound を失いうる。秒単位で戻したいなら
pgBackRest で WAL アーカイブ → Point-In-Time Recovery。**夜次ダンプは dumb fallback として残す。**

設計(有効化は基本バックアップの蛇口と一緒か直後):

1. ホストに pgBackRest を入れ、repo を B2 に置く(`/etc/pgbackrest/pgbackrest.conf`:
   `repo1-type=s3`, `repo1-s3-bucket=...`, `repo1-retention-full=2`)。
2. `config/deploy.yml` の postgres `cmd:` に WAL アーカイブを足す(常時オン):
   ```yaml
   cmd: >-
     postgres
     ... 既存のチューニング ...
     -c archive_mode=on
     -c archive_command='pgbackrest --stanza=sukhi archive-push %p'
     -c wal_level=replica
   ```
   `kamal accessory reboot postgres` で反映。
3. stanza を作って初回フルバックアップ:
   ```sh
   docker exec sukhi-fedi-postgres pgbackrest --stanza=sukhi stanza-create
   pgbackrest --stanza=sukhi backup
   pgbackrest --stanza=sukhi verify
   ```
4. PITR 復元: `pgbackrest --stanza=sukhi --type=time "--target=2026-06-01 14:32:00" restore`。

WAL-G ではなく pgBackRest を選ぶのは、retention / full・incr・diff / verify が
batteries-included で操作ミスが減るから(単一ホストでは footprint 差より効く)。

> 注意: PITR は「壊れたデータの直前に **全体** を戻す」操作で、外部から来た悪いデータの
> 訂正には向かない(良い変更も巻き戻る)。そこは外科的訂正(`RebuildFromArchive`)の担当。

## OCI フリーティア(1GB)向け

同じスクリプトを **dump-only**(PITR 無し)、宛先 Cloudflare R2(egress 無料・cloudflared 既設)、
隔日、で回す。restic は軽いのでそのまま使える。`restic backup` の前に
`zstd`/CPU を食わないよう `--compression auto` で十分。

## 正直な tradeoff / 非ゴール

- 夜次ダンプは総ホスト喪失で最大 ~24h の自作 outbound を失いうる(inbound は replay 可、
  peer から再取得可)。気になれば A4 の PITR で解消。
- `restic restore` の `--include` パターンはあなたの restic バージョンで一度確かめる
  (パスの先頭一致の扱いがバージョンで微妙に違う)。フォールバックは `restic restore latest
  --target /tmp/all` で丸ごと出してから拾う。
- restic が rustfs の **ディレクトリ**を取るので、rustfs の on-disk レイアウトに依存する。
  レイアウトが将来変わったら `rclone sync` でバケット単位コピーに切り替える(documented fallback)。
- NATS の OUTBOX ストリームは別途バックアップしない(in-flight な配送は一時的で、Postgres の
  状態から再 enqueue される)。
- ログは immutable ではない(tamper-evident が要るなら object-lock、今回は範囲外)。
