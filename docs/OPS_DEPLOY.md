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

## 2. 更新する

更新は、**準備 → 入れる → 確かめる → 戻せるようにしておく**の順。

### 2.1 いまの手順(`sukhi release` ができるまで)

本番(haloy)の場合:

1. main に push すると、GitHub Actions が `sha-<commit>` で image を GHCR に出す(自動)。
   **四つの image(combined / anubis / natadeco-ssr / web-next)が、同じ sha でそろっている**ことを確かめる。
2. その sha の build が成功していることを確かめる。
3. 更新の前に、**控えが新しいか**を見る(OPS_MAINTAIN.md §3)。
4. sukhi-deploy の `haloy.yaml` の image タグを、新しい sha に書き換える(四つとも同じ sha)。
5. `haloy deploy -t sukhi-fedi-app`。
6. §2.3 の確かめ。

自前ホスト(Compose)の場合: [`RUNTIME.md`](RUNTIME.md) §5 の四拍子(検証 → 取得 → 再作成 → 確認)。

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
