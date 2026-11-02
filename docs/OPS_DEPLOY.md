<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# ② デプロイ(最初の起動、更新、戻し)

> 入口は [`OPERATIONS.md`](OPERATIONS.md)。準備([`OPS_PREPARE.md`](OPS_PREPARE.md))が済んでいる前提。
> `sukhi release` などは**予定**([`SERVER_SHELL.md`](SERVER_SHELL.md))。「いまの手順」を併記する。
> 手順は読み取りの要約で、**実機では通していない**。

## 1. 最初の起動

### 1.1 リポジトリと設定

```bash
git clone https://github.com/sukhi-social/sukhi-fedi && cd sukhi-fedi
make preflight          # 出す前の点検(infra/preflight.sh。過去の事故の再発を見る)
```

`.env` は OPS_PREPARE.md §6 のとおり。

### 1.2 起動(Datalevin 構成)

```bash
docker compose \
  -f docker-compose.yml -f docker-compose.combined.yml -f docker-compose.datalevin.yml \
  up -d
# Podman なら docker を podman に。Compose の重ね合わせが通るかは未確認(RUNTIME.md §2)
```

- 起動のとき、`entrypoint` が `migrate_all()` を実行する。**Datalevin では何も移行しない**
  (スキーマは `priv/datalevin/catalog.exs` から導かれ、ストアを開くときに入る)。Postgres では移行が走る。
- `ERLANG_COOKIE` が既定のままだと、**起動を断る**(安全のため)。
- `DOMAIN` と `SECRET_KEY_BASE` が無い場合も起動を断る。Datalevin 構成では
  `DATALEVIN_DIR` (既定 `/var/lib/sukhi/datalevin`) を作成でき、書き込めることを
  起動前に検査する。秘密値そのものは journal に出ない。
- journal には `migration_start` / `migration_complete` が出る。Postgres の場合は
  repo 単位の開始・完了も出るので、初回 migration が止まった場所を確認できる。
- migration/init または NATS の接続確認が失敗した場合、entrypoint は `start` に
  進まず終了する。`startup_connection_ok service=nats` と
  `datalevin_init_complete` と `startup_checks_complete` が出るまで、コンテナは
  起動完了とはみなさない。
  Postgres migration の失敗時も接続先と `podman logs <postgres-container>`、
  `nc -vz <host> <port>` の確認方法を journal に残す。
  NATS の失敗時は journal に接続先と `nc -vz <host> <port>` の確認方法が出る
  (secret やパスワードは出ない)。
- `/up` は BEAM が HTTP 応答できるかだけを返す liveness (`200 ok`)。Quadlet の
  `HealthCmd=wget -q -O /dev/null http://127.0.0.1:4000/up` と同じ責務で、
  DB や migration の readiness 判定には使わない。
- 非秘密の site name・logo/icon・frontend・upstream・route は
  `config/instance.json.example` を `/etc/sukhi/instance.json` として read-only
  mount し、Quadlet の `SUKHI_INSTANCE_CONFIG` で指定する。ファイルは必須で、
  `routes` の各行で `frontend` を明示する。選択肢は `relay`（内蔵）、
  `web-next`、`web-simple`、`web-board`、`web-lobby`（予定）。起動時に解決した
  path、frontend、active frontend/route 件数と構文不整合を journal に出す。
  外部 frontend は route で参照されたものだけ接続対象になる。秘密はこのファイルへ
  入れず、env/Podman secret で渡す。
- `/etc/sukhi` の Stow 管理、symlink の向き・所有者・実体ファイル・想定 repo
  revision の検査、および不正時に Quadlet 同期を止める処理は
  `sukhi-setup`/`sukhi-infra` 側の同期前 preflight の責務とする。`sukhi-fedi`
  image は同期済みの mount を信頼して起動するのではなく、解決した JSON の
  構文と upstream/route の整合性を再検査するが、ホスト側 repo や Stow の
  所有権を推測して検査することはしない。
- 新しい版を取るのは `.env` の `SUKHI_VERSION`。本番では `sha-<commit>` か、ダイジェストに固定する。

### 1.3 玄関を向ける

nginx を Anubis(`127.0.0.1:8080`)に向ける(RUNTIME.md §9)。`nginx -t` のあと `reload`。

### 1.4 確かめ

```bash
docker compose ps                      # 全部 running / healthy か
docker compose logs --tail=100 gateway # エラーが続いていないか
curl -sI https://example.tld/ | head -1
curl -s https://example.tld/.well-known/webfinger?resource=acct:<ユーザー>@example.tld | head -c 200
```

- 管理画面 `/admin`(ブラウザ)に入れる。
- 登録 → メールの確認コード → 投稿ができる。
- **メールが飛ばない**ときは、SMTP の設定を見る。ログに確認コードが出ている(`SMTP_*` が未設定の場合)。

### 1.5 最初の管理者

最初のアカウントを作り、管理者にする手順は、リポジトリの README / SETUP.md を参照
(**ここでは未確認**。実機で確かめて追記する)。管理者にはパスキーの登録をすすめる。

### 1.6 初回起動の受け入れ手順(Podman / Quadlet)

以下は rootless の専用ユーザー `sukhi` で実行する。root は一度だけ
ユーザー・linger・必要なディレクトリを用意し、その後は Quadlet の操作を
しない。

#### A. Linux 初心者向け(最短)

root で一度だけ:

```bash
sudo useradd -m -s /bin/bash sukhi          # 既にあれば失敗してよい
sudo loginctl enable-linger sukhi
sudo install -d -o sukhi -g sukhi /etc/sukhi /var/lib/sukhi
```

`sukhi` で:

```bash
sudo -iu sukhi
podman secret create erlang_cookie ./secrets/erlang_cookie
podman secret create secret_key_base ./secrets/secret_key_base
install -m 0644 ./config/instance.json.example "$HOME/instance.json"
# Quadlet の /etc/sukhi/instance.json mount は、実際の unit のパスに合わせる
systemctl --user daemon-reload
systemctl --user enable --now sukhi-gateway
systemctl --user status sukhi-gateway --no-pager
journalctl --user -u sukhi-gateway -n 100 --no-pager
```

成功の目印は `startup_connection_ok service=nats`,
`datalevin_init_complete`, `startup_checks_complete`。`/up` は liveness
だけなので、Quadlet の `HealthCmd` は `wget -q -O /dev/null
http://127.0.0.1:4000/up` のまま使う。

#### B. 途中まで実行済み・既存ユーザー/secret/volume がある場合

破壊的な `podman volume rm`、`podman system reset`、Datalevin directory の
削除を先に実行しない。まず `sukhi` で:

```bash
podman secret ls
podman volume ls
systemctl --user list-units --all 'sukhi*'
systemctl --user status sukhi-gateway --no-pager
journalctl --user -u sukhi-gateway -n 100 --no-pager
```

既存 secret は値を表示せず、名前だけを Quadlet の `Secret=` と照合する。
既存 volume は停止してから mount 先だけ確認する。entrypoint が
`instance config is missing or unreadable`、`DATALEVIN_DIR is not writable`、
manifest/catalog mismatch のいずれかを出した場合、既存データは開かず変更
していないので、ログに示された path/owner/mount を直してから再実行する。

#### C. `sukhi` ユーザーが既に存在する場合

`useradd` を繰り返さず、root では:

```bash
id sukhi
sudo loginctl enable-linger sukhi
sudo -iu sukhi
```

以降の `podman`、`secret`、`volume`、`systemctl --user`、`journalctl --user`
はすべて `sukhi` で実行する。

#### D. root で誤って Podman/Quadlet を実行した場合

rootful Podman のコンテナは rootless `sukhi` のコンテナから見えない。root
側の `podman ps` が空でも、`sukhi` 側のサービスが停止した証拠ではない。
root で実行した unit を止め、`sukhi` に切り替えて確認する:

```bash
sudo systemctl disable --now sukhi-gateway 2>/dev/null || true
sudo -iu sukhi systemctl --user daemon-reload
sudo -iu sukhi systemctl --user enable --now sukhi-gateway
sudo -iu sukhi journalctl --user -u sukhi-gateway -n 100 --no-pager
```

既存の rootful container/volume を削除する前に、`podman inspect` と volume
名を控える。Datalevin は `sukhi` の volume にコピーできることを確認する
まで削除しない。

#### E. migration/init が未実行または失敗した場合

`startup_checks_complete` が出ていなければ起動完了ではない。Postgres は
`migration_start` の後に `migration_complete` が必要で、Datalevin は
`store_init_start` の後に `datalevin_init_complete` が必要。失敗時は
entrypoint が `start` に進まない。

```bash
journalctl --user -u sukhi-gateway -n 150 --no-pager
nc -vz <db-host> <db-port>       # Postgres の場合
podman logs <postgres-container>  # Postgres の場合
```

既存 Datalevin の復元では、停止済み旧 writer から全 persistence unit を
戻し、`SukhiFedi.Release.check_datalevin_backup_manifest!()` を先に実行する。
catalog mismatch、queue DB 欠落、graph 欠落は起動前に拒否され、データは変更
されない。

#### F. NATS/DB/frontend upstream がつながらない場合

NATS は `startup_connection_ok service=nats` が出なければ起動しない。ログの
endpoint と `nc -vz` の結果を確認する。DB は migration error に endpoint と
`podman logs <postgres-container>` が出る。どちらも secrets の値は出さない。

frontend upstream は gateway 自体を止めず、該当 route を unavailable として
扱う。ログには frontend 名、設定 URL、次の確認用 `wget` コマンド、
`sukhi` ユーザーで実行すること、既存データを変更していないことが出る:

```bash
podman exec <gateway-container> \
  wget -S -O - http://web-next:3000/.sukhi/web.json
```

upstream が戻ると manifest を再取得し、last-known-good の claims を維持する。
`/up` が 200 でも upstream/readiness の成功を意味しない。

## 2. 更新する

更新は、**準備 → 入れる → 確かめる → 戻せるようにしておく**の順。

### 2.1 いまの手順(`sukhi release` ができるまで)

共通の準備(どの入れ替え方でも):

1. main に push すると、GitHub Actions が `sha-<commit>` で image を GHCR に出す(自動)。
   **四つの image(combined / anubis / natadeco-ssr / web-next)が、同じ sha でそろっている**ことを確かめる。
2. その sha の build が成功していることを確かめる。
3. 更新の前に、**控えが新しいか**を見る(OPS_MAINTAIN.md §3)。

入れ替え方は、環境に合わせて一つ:

- **Compose(自前ホスト・基準)**: `.env` の `SUKHI_VERSION` を新しい sha に書き換えて、
  [`RUNTIME.md`](RUNTIME.md) §5 の四拍子(検証 → 取得 → 再作成 → 確認)。
- **haloy(今の本番。任意の一つのやり方)**: sukhi-deploy の `haloy.yaml` の image タグを新しい sha に
  (四つとも同じ sha)書き換え、`haloy deploy -t sukhi-fedi-app`。

そのあと §2.3 の確かめ。

### 2.2 予定の手順(`sukhi release`)

```
sukhi release              # 計画を出して止まる(何も変えない)
sukhi release --execute    # 版の番号を打ち直して実施 → 告知 → 数分後に再起動
sukhi release status
```

計画に出るもの、確認の仕方、署名の検証、告知とカウントダウンは [`SERVER_SHELL.md`](SERVER_SHELL.md) §5。

### 2.3 更新のあとの確かめ

- `docker compose ps` / `logs --tail=100 gateway` にエラーがない。
- 新しい版を名乗っている(管理画面か、`sukhi status`(予定)。表示の場所は実機で確かめる)。
- 投稿・タイムライン・通知が普通に動く。
- 配信キューが流れている(溜まり続けていない)。
- 5〜10 分、様子を見る。

### 2.4 告知(利用者への)

更新のたびに、**先に**お知らせを出す(管理画面の「お知らせ」。公開期間つき)。例:

> あと 10 分ほどで、ほんの少しのあいだ再起動します。そのまま使っていて大丈夫です。

## 3. 戻す

おかしいと思ったら、**慌てずに、戻れる道を選ぶ**。

| 状況 | 戻し方 | 注意 |
| --- | --- | --- |
| 版を上げたら動かない(データの形は変わっていない) | 前の `sha-…` に書き戻して、もう一度入れる | いちばん軽い。まずこれ |
| データの形が変わる版だった | 前の image に戻したうえで、**更新前の控えから復元**が要るかもしれない | **先に相談**(Matrix)。復元の前に、いまの状態の控えも取っておく |
| 設定の誤り | `.env` を直して再作成 | image は変えない |

- Datalevin は、スキーマ追加だけの変更なら前の版からも読める見込みがあるが、**検証していない**
  (SERVER_SHELL.md §5.6)。戻しの判断は、版ごとの互換の宣言ができるまで人が行う。
- 戻したあとも、**告知を書き換える**(「更新を見送りました」)。

## 4. こうなったら(早見)

| 症状 | まず見るところ |
| --- | --- |
| 起動しない | `docker compose logs gateway`。`ERLANG_COOKIE` が既定でないか、`DOMAIN` が入っているか |
| 登録の確認コードが届かない | `SMTP_*` と `MAIL_FROM`。未設定ならログに出ている |
| 他のサーバーから届かない | nginx が `Host` を渡しているか(RUNTIME.md §9.2)。`DOMAIN` と同じ名前か |
| 画像が上げられない | `S3_ENDPOINT` と鍵。未設定なら `not_configured` |
| 重い・メモリが足りない | `DATALEVIN_XMX` と `ERL_FLAGS`、小さな箱の値(DATALEVIN.md) |
