<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Quadlet + GitOps で更新する(設計案)

> 状態: **設計は合意済み(ひなた, 2026-11-01「良さそう」)。実装は `sukhi-infra` / `sukhi-setup` に雛形が入った。実機では何も通していない。** 残りの決めごとは §12。
> 正本の方針は [`RUNTIME.md`](RUNTIME.md) §12.3(Quadlet が主、image はダイジェストで固定)、
> 更新の流れは [`SERVER_SHELL.md`](SERVER_SHELL.md) §5、今ある最小の手作業版は
> [`OPS_UPDATE_QUADLET.md`](OPS_UPDATE_QUADLET.md) と `scripts/sukhi-swap-image.sh`。
> この文書は、それらを「**git の main が、箱の状態の正本**」という形にまとめ直す案。
> 前提(ひなた, 2026-10-30): 常駐は Quadlet / rootless / 専用ユーザー `sukhi` / バックエンドは Datalevin。

## 0. 一言で

```
タグ v1.0.0 ─▶ release.yml が 5 つの image に同じ版(1.0.0)を付ける・cosign 署名
(dev は main への push ─▶ combined-sha.yml の sha-<commit>)
                    │
                    ▼
           sukhi-infra に「ダイジェストを上げる PR」が自動で立つ
                    │  人が読んで承認(必須レビュー・署名つきコミット)
                    ▼
        sukhi-infra の main にマージ(ここが「上げる」という意思の記録)
                    │
                    ▼  5 分ごとに systemd timer が引く(箱から外へ。外から箱へ入らない)
   署名検証 ─▶ 変わった unit だけ try-restart ─▶ ヘルスを待つ
                    │ 通らなければ                    │ 通れば
                    ▼                                 ▼
        前の commit に git reset、元に戻す       完了を記録(journal + 通知)
```

- **箱に入る鍵を CI に渡さない**(pull 型)。CI が持つのは「PR を立てる」権限だけ。
- **ダイジェストは git に残る**。いつ・誰が・何を上げたかは `git log`、戻す先は `git revert`。
- `AutoUpdate=registry` は使わない(署名を見ない・git の外で動く。RUNTIME.md §12.3)。

## 1. 部品と置き場所

| 部品 | 置き場所 | 中身 |
| --- | --- | --- |
| アプリ本体・image の CI | `sukhi-fedi`(いま) | `combined-sha.yml` / `release.yml`。**ダイジェストを出力**し、`sukhi-infra` へ PR を立てる job を足す |
| Quadlet の正本(**箱が自動で引く**) | **`sukhi-infra`**(決定: ひなた, 2026-11-01) | `base/` と `overlays/<env>/`(§1.1)。**これだけが自動で適用される** |
| 初回の準備と検証役(**人が手で入れる**) | **`sukhi-setup`**(決定: 同上) | ユーザー・linger・`podman secret` の手順、同期スクリプト、timer / service、`allowed_signers` の入れ方 |
| 秘密 | **git に置かない** | `podman secret`(§6) |
| 箱の信頼の根 | 箱の上(`/etc/sukhi/`) | `allowed_signers`(コミット署名の公開鍵)、cosign の身元(正規表現)、環境名(`/etc/sukhi/env`) |

**infra と setup を分ける理由は、検証役を自動適用の外に置くため。** 同期スクリプトが `sukhi-infra` の中にあると、
`sukhi-infra` を書き換えた人が検証の仕組みごと書き換えられる。setup は人が手で入れ、infra は署名と必須レビューで固める。
`sukhi-infra` には terraform などの「人が手で流すもの」を入れない(それは `sukhi-fedi/infra/` のまま)。

### 1.1 sukhi-infra の構成(base + overlays)

```
sukhi-infra/
├── base/                         # 全環境共通
│   ├── sukhi.network
│   ├── sukhi-data.volume
│   ├── sukhi-nats.container
│   ├── sukhi-gateway.container   # Image= はここ(Renovate / bump が見る)
│   ├── sukhi-web-next.container
│   ├── sukhi-web-simple.container
│   ├── sukhi-web-board.container
│   └── sukhi-anubis.container
└── overlays/
    ├── dev/
    │   └── sukhi-gateway.container.d/override.conf   # 例: DOMAIN、メモリ、ログの量
    └── prod/
        └── sukhi-gateway.container.d/override.conf
```

- 「`quadlets/containers/systemd/` の入れ子」は作らない。Quadlet が読むのは `~sukhi/.config/containers/systemd/` の**一か所**で、
  同期スクリプトが `base/` の上に `overlays/$SUKHI_ENV/` を**重ねて平らに書き出す**(`rsync -a base/ out/ && rsync -a overlays/$ENV/ out/`)。
  `$SUKHI_ENV` は箱の `/etc/sukhi/env`(git に置かない)から取る。
- 重ね方は Quadlet 自身のドロップイン(`<unit>.container.d/*.conf`)に任せる。同じキーは**後のファイルが勝ち**、
  `Environment=` のような列は**足される**(空の `Environment=` で一度消せる)。この挙動は Podman の版で確かめる(§12-6)。
- **`Image=` は base に置く。** Renovate はドロップインを見ない(§9)。dev だけ先の sha にしたいときは overlay に `Image=` を置いてよいが、
  その行は bump の対象外なので、prod へ上げるときは PR でダイジェストを写す(昇格 = base への PR)。
- 箱は自分の環境の差分だけを見る: 差分の判定(§3.4)は `base/` と `overlays/$ENV/` の変更だけが対象。
  `overlays/dev/` の変更で prod の箱は何もしない。
- 箱が複数になったら、`overlays/<env>/` を `overlays/<host>/` に細かくするか、環境の下に箱を足す(今は決めない)。


## 2. sukhi の構成を unit にあてはめる

rootless、ユーザー `sukhi`、`~sukhi/.config/containers/systemd/` に置く。unit 名はファイル名から決まる
(`sukhi-gateway.container` → `sukhi-gateway.service`)。

| unit(ファイル) | 何か | image | 備考 |
| --- | --- | --- | --- |
| `sukhi.network` | 内部ネットワーク | — | 外に出すのは Anubis の 8080 だけ(127.0.0.1) |
| `sukhi-data.volume` | Datalevin + 配信キュー(SQLite) | — | `/var/lib/sukhi` に `datalevin/` `queue.db` `delivery_queue.db`。**更新で消さない**。`:Z` を付ける(SELinux) |
| `sukhi-nats.container` | NATS | `nats:2-alpine`(ダイジェスト固定) | gateway が `Requires=` する(起動しないと動かない依存はこれだけ) |
| `sukhi-gateway.container` | **combined**(gateway + delivery + api の一つの BEAM) | `ghcr.io/sukhi-social/sukhi-fedi-combined` | `SUKHI_STORE=datalevin`、`WEB_UPSTREAMS=web-next=http://sukhi-web-next:3000,…`。**書き手が一つ**なので、複製・ローリングは不可(再起動の間は短く止まる) |
| `sukhi-web-next.container` | web-next(いまの主軸のフロント) | `…/sukhi-fedi-web-next` | `/.sukhi/web.json` を返す。gateway が起動時と 30 秒ごとに読む |
| `sukhi-web-simple.container` | 旧 `web/`(SvelteKit SPA)。維持のみ | `…/sukhi-fedi-web-simple` | 同上。**使わない箱では置かない**(unit を足さなければ動かない) |
| `sukhi-web-board.container` | natadeco の SSR(旧 natadeco-ssr) | `…/sukhi-fedi-web-board` | 別ドメイン。同じ箱で動かすかは §12-7 |
| `sukhi-anubis.container` | Anubis | `…/sukhi-fedi-anubis` | `PublishPort=127.0.0.1:8080:8080`。ホストの nginx がここへ向く(RUNTIME.md §9) |
| (対象外)Postgres | 旧構成 | — | 維持のみ。Postgres 版の unit は本書では書かない |
| (対象外)rustfs / S3 | メディア置き場 | — | 使う箱では同じ形の unit を足す |

起動順は `After=` で表し、「落ちたら一緒に止める」ほどの依存だけ `Requires=` にする:

- gateway → `After=`/`Requires=` nats。web-* と Anubis は gateway に `After=` だけ(落ちていても起動はする)。
- **`Wants=network-online.target` は書かない。** rootless の user unit からは system の target に効かない
  (user manager は別の systemd。効くと思って書くと、効かないまま残る)。外向きの接続は gateway が再試行する。
  Quadlet が自動で付ける依存(network / volume)に任せる。
- sukhi の 5 つの image の版を揃えるのは `sukhi.version`(§5)。unit 同士の起動順とは別の話。

### 2.1 gateway の例(未検証)

```ini
# ~sukhi/.config/containers/systemd/sukhi-gateway.container
[Unit]
Description=sukhi gateway (combined)
Requires=sukhi-nats.service
After=sukhi-nats.service

[Container]
ContainerName=sukhi-gateway
# 版とダイジェストは overlays/<env>/sukhi.version の値で、箱の同期スクリプトが埋める(§5)。実体はダイジェストが決める。
Image=ghcr.io/sukhi-social/sukhi-fedi-combined:{{version}}@{{digest:combined}}
Network=sukhi.network
Volume=sukhi-data.volume:/var/lib/sukhi:Z
Environment=DOMAIN=example.tld SUKHI_STORE=datalevin DATALEVIN_DIR=/var/lib/sukhi/datalevin
Environment=SUKHI_QUEUE_DB=/var/lib/sukhi/queue.db DELIVERY_QUEUE_DB=/var/lib/sukhi/delivery_queue.db
Environment=WEB_UPSTREAMS=web-next=http://sukhi-web-next:3000
# 秘密は事前に作っておく(§6)。entrypoint.sh が /run/secrets/<NAME> を 1 変数 1 ファイルで読む。
Secret=erlang_cookie,type=mount,target=ERLANG_COOKIE
Secret=secret_key_base,type=mount,target=SECRET_KEY_BASE
Label=app=sukhi
DropCapability=ALL
NoNewPrivileges=true

# ヘルス(§4): image に curl は無い。Alpine の busybox wget を使う。
HealthCmd=wget -q -O /dev/null http://127.0.0.1:4000/up
HealthInterval=15s
HealthTimeout=3s
HealthRetries=3
HealthStartPeriod=90s
HealthOnFailure=kill
Notify=healthy

[Service]
Restart=on-failure
RestartSec=5
TimeoutStartSec=180

[Install]
WantedBy=default.target
```

- `/up` は gateway に既にある(`router.ex`、`ok` を返すだけ)。DB まで見るわけではない。深いヘルスが要るかは §12-8。
- `Label=` は `key=value` の形で、**識別のための印にだけ使う**。`io.containers.autoupdate` のようなラベルで更新を動かさない(§0)。
- `ReadOnly=true` + 書く場所だけ volume/tmpfs は、最初は付けない(Erlang の書き込み先を洗ってから。RUNTIME.md §12.3)。

## 3. 更新の流れ(GitOps ループ)

### 3.1 CI(sukhi-fedi 側)

1. **prod:** `v*.*.*` のタグで `release.yml` が 5 つの image(combined / web-next / web-simple / web-board / anubis)に**同じ版**(`1.0.0` `1.0` `v1`)を付け、cosign で署名する(いま動く形。タグはまだ無い)。
   **dev:** main への push で `combined-sha.yml` が `sha-<commit>` を出し、署名する。
2. 追加: リリース(または main)の最後の job が `scripts/bump-version.sh <env> <版>` を回して `sukhi-infra` に PR を立てる(5 つのダイジェストを `skopeo` で解決して `overlays/<env>/sukhi.version` を書き換える)。
   - 立てるのは **GitHub App のトークン**(`sukhi-infra` への `pull_requests: write` と `contents: write` の一部だけ。main へは直接書けない)。
   - PR の中身は `sukhi.version` の書き換えだけ。本文に前回からの `git log` の件名、マイグレーションの有無
     (Datalevin は無し)、データ形が変わるかの印(§7)を載せる。
3. 5 つのうち 1 つでも解決できなければ書き換えない(`bump-version.sh` は全部解決してから書く)。
   **この CI の job はまだ無い。** 当面は手で `scripts/bump-version.sh` を回して PR を出す。

### 3.2 sukhi-infra(承認の関所)

- 必須チェック(PR 上で走る):
  - **署名検証**: 埋めたあとの sukhi の image すべてに `cosign verify`(身元は `release.yml@refs/tags/v*` か `combined-sha.yml@refs/heads/main`。`sukhi-swap-image.sh` と同じ正規表現)。
  - **Quadlet の文法検査**: `podman-system-generator --dryrun` 相当(または `quadlet -dryrun`)を CI で回し、unit が生成できることを見る。
  - `sukhi.version` の形(prod は semver、dev は semver か `sha-<commit>`、digest が 5 つ揃う、`requires-sync` がある)。埋め方は sukhi-setup の `sukhi-render` を使う(`scripts/check.sh`)。
- 人が読んで承認する。**PR を立てた bot は承認できない。**

### 3.3 箱(同期)

同期スクリプトと timer / service は **`sukhi-setup` の側**にあり、人が手で入れる(`sukhi-infra` の中からは更新されない。§1)。

`sukhi-gitops-sync.timer` が `OnCalendar=*:0/5`(5 分ごと)、`RandomizedDelaySec=30`、`Persistent=true` で
`sukhi-gitops-sync.service`(`Type=oneshot`)を起こす。**cron ではなく systemd timer** にする理由:

- 実行は journald に残る(`journalctl --user -u sukhi-gitops-sync`)。cron は別途メールかリダイレクトが要る。
- 同じ unit は重ならない(前の回が長引いても、次の回が割り込まない)。cron は `flock` を自分で書く。
- `Persistent=true` で、止まっていた間の分を起動後に取り返す。`OnFailure=` で通知の unit を呼べる。
- `infra/backup/` が既に timer の形なので、同じ作法に揃う。

`sukhi-gitops-sync` の手順(一回分。実装は `sukhi-swap-image.sh` の `switch_to` を土台にする):

```
 0. flock(二重起動の保険)。state: ~/.local/state/sukhi-gitops/{last-good,rejected,history}
 1. git fetch origin main
 2. target = origin/main の先頭。last-good と同じなら終わり。rejected と同じなら終わり(同じ失敗を繰り返さない)
 3. 【信頼】target の署名を allowed_signers で検証(git verify-commit)。通らなければ何も変えず通知して終わり
 4. 【信頼】last-good..target の差分で Image= が変わった全ダイジェストに cosign verify。1 つでも通らなければ同上
 5. 差分のファイルから「変わった unit」を求める(§3.4)
 6. git merge --ff-only target(ff できなければ止めて通知。履歴の書き換えは受けない)
 6b. base/ + overlays/$SUKHI_ENV/ を一時ディレクトリに重ねて書き出し、Quadlet のディレクトリに入れ替える(§1.1)
 7. daemon-reload
 8. 変わった unit を依存の順に try-restart(§3.4)。Notify=healthy なので、各 restart は「ヘルスが通るまで」戻らない
 9. 全部通ったら 3 秒 + 30 秒保持して再確認(起動直後だけ active な暴れ方を弾く)→ last-good = target、history に一行
10. どこかで失敗したら §3.5
```

### 3.4 `daemon-reload` だけでは再起動されない

`systemctl --user daemon-reload` は unit の定義を読み直すだけで、**動いているコンテナはそのまま古い image で動き続ける**。
再起動が要る。だから:

- 差分(`git diff --name-only last-good target`)から、変わった `*.container` / ドロップイン(`*.container.d/*.conf`)を unit 名に直す。
- それらを **`try-restart`**(動いていなければ起こさない)。動いていない unit を巻き込んで起こさないため。
- `*.network` / `*.volume` が変わったら、それを使う unit も対象に足す(ただし既存の network / volume は作り直されないことがある。変更は手で確認 = 本書では「承認の PR に印を付ける」だけ)。
- **順序**: nats → gateway → web-* → anubis。gateway と web-* は `web.json` の取り込みが 30 秒周期なので、web-* を先に上げると
  gateway が古い `web.json` を持つ間だけ食い違う。gateway が先。
- 「変わっていない unit は触らない」ので、web-next だけの更新で gateway(Datalevin の書き手)は止まらない。
- 起動は stop→start(§2)。Datalevin の書き手が一つなので、gateway の更新は短い断が必ずある。告知は SERVER_SHELL.md §5.8 の仕組みに載せる(§8)。

### 3.5 更新後のヘルス待ちと、失敗したら戻す

- 通らなかった(`restart` が非 0、`TimeoutStartSec` 内に healthy にならない、保持の再確認で落ちた):
  1. `rejected` に target を記録(以後、この commit は再試行しない)。
  2. **チェックアウトは成功するまで進めない**(実装: `git archive <target>` で作業用に展開し、成功したときだけ `git reset --hard <target>`)。
     失敗時に戻すのは Quadlet のディレクトリ(最後に適用した状態 `applied/` を書き戻す)で、sukhi-infra の main は書き換えない。
  3. `daemon-reload` → 変わっていた unit を `try-restart`。戻した側も通らなければ、止めて通知(これ以上は人)。
  4. 通知: journal、`OnFailure=` の unit、管理画面の「お知らせ」(§8)。
- 箱の checkout は**デプロイ専用**(人が編集しない・push しない)。reset が安全なのはそのため。
- 戻したあとも origin の main は壊れた版のまま。**人が `git revert` の PR を出す**(それで `rejected` が自然に外れて、次の commit が対象になる)。
  PR を放置しても箱は last-good のままで安全。
- **自動で戻してよいのは、image と unit だけ。** データの形が変わる版(§7)は、戻しても元に戻らないことがある。

### 3.6 手動の道(最後の砦)との関係

`scripts/sukhi-swap-image.sh` は残す。ただし GitOps の箱では**非常用**にする:

- ドロップイン `10-image.conf` が git の `Image=` を上書きするので、**git の外の状態**ができてしまう。
  同期スクリプトは、`*.container.d/10-image.conf` がある unit を見つけたら**警告して通知**し、
  `--clear-overrides` で消せるようにする(黙って食い違いを残さない)。
- `sukhi release`(SERVER_SHELL.md §5.1)は GitOps の箱では「sukhi-infra の bump PR を作る/マージする」+
  「`sukhi-gitops-sync --now`(待たずに一回)」の入口にする。**updater が二通りの更新の仕方を持たない**(§5.10 の方針と同じ)。
- 画面が壊れた夜・GitHub が落ちた夜は、箱の上で `sukhi-swap-image.sh apply` が使える(署名検証つき)。

## 4. ヘルスと再起動の持ち主を一つにする

| 論点 | 案 |
| --- | --- |
| `HealthOnFailure=restart` | **使わない。** 再起動を podman と systemd の両方が持つと、`Restart=` と二重に動いて何が起きたか追えない。`HealthOnFailure=kill`(コンテナを落とす)にして、**再起動は systemd の `Restart=on-failure` が一人で持つ** |
| image に curl が無い | Alpine なので busybox の **`wget -q -O /dev/null`**(HTTP の異常で非 0)。node:24-alpine の web-* も同じ。curl を足して image を太らせない。wget も無い image が出たら `CMD` に node/erl の短い確認を書く |
| 起動中の誤判定 | combined は起動時に `migrate_all()`(Datalevin では実質何もしない)と BEAM 起動がある。`HealthStartPeriod=90s` 以上にして、この間の失敗は数えない |
| 更新の完了待ち | **`Notify=healthy`**: unit が「起動完了」になるのをヘルスが通ってからにする。`systemctl restart` がそこまで戻らないので、同期スクリプトの「ヘルスを待つ」はこれに乗れる |
| Podman の版 | `HealthOnFailure=` `Notify=healthy` などのキーは Podman の版で入った時期が違う。**箱の版で `man podman-systemd.unit` を確かめてから確定**(§12-6)。効かないキーは systemd が警告して無視する場合と、unit が生成されない場合がある |
| 深いヘルス | `/up` は「BEAM が答える」だけ。Datalevin が開けたか・キューが詰まっていないかは別の口が要る(OPS_UPDATE_QUADLET.md §6 の未確認と同じ) |

## 5. 版を `sukhi.version` に集約する

決定(ひなた, 2026-11-01): sukhi-infra は**期待する版を 1 か所に書く**。`overlays/<env>/sukhi.version`:

```
requires-sync: 1                  # この形式を読める同期スクリプトの版。古い箱は適用せず通知する
version: 1.0.0                    # prod はリリースの semver、dev は main の sha-<commit>
digest.combined: sha256:<64桁>    # web-next / web-simple / web-board / anubis も同じ
```

- base の unit は `Image=ghcr.io/sukhi-social/sukhi-fedi-<name>:{{version}}@{{digest:<name>}}`。**埋めるのは sukhi-setup の `bin/sukhi-render` の一か所**
  (箱の同期と sukhi-infra の CI が同じものを使う。infra の中に埋め方を置くと、infra を書き換えた人が検証の仕組みごと書き換えられる)。
  知らない記法・manifest に無いキーは失敗する(Quadlet に `{{ }}` が渡らない)。第三者の image(nats)は素の `<name>:<tag>@sha256:…`。
- **5 つの image が同じ版で揃う**のは、タグを 1 回打つと 5 つに付くことと、manifest が 1 か所であることで守られる。
  部分的に上がった状態を作らない(1 回の同期が全部の `try-restart` を通し、途中で失敗したら全体を last-good に戻す = §3.5)。
- 変化の検出は**埋めたあとの `Image=` の差**。`digest.combined` だけ変われば gateway だけ、版を上げれば 5 つの unit が動く(nats は動かない)。
- **prod は厳密な版 + ダイジェスト**(`1.0.0@sha256:…`)。`v1` / `latest` のような動くタグは書かない。dev は `sha-<commit>` で main に追従。
- semver なので順序があり、Renovate でも扱える見込みだが、`{{version}}` の形は Renovate の Quadlet マネージャが読めない。当面は `bump-version.sh` で上げ、
  第三者の image だけ Renovate にする(§9)。
- 代償: prod に出すたびに `vX.Y.Z` のタグを切る。

## 6. 秘密(podman secret)

- git に入れない。`ERLANG_COOKIE`、`SECRET_KEY_BASE`、SMTP、S3 などは `podman secret` に。
- **事前作成は準備の手順**に入れる(OPS_PREPARE.md)。unit は秘密が無ければ起動に失敗する(失敗の仕方が分かりやすい):

```sh
# 箱で、ユーザー sukhi として。標準入力から作る(コマンドライン引数やシェル履歴に残さない)
umask 077
openssl rand -hex 32 | podman secret create erlang_cookie -
openssl rand -hex 64 | podman secret create secret_key_base -
podman secret ls            # 名前だけが出る。値は出ない
```

- 更新: 同じ名前では上書きできないので、`podman secret rm` → `create` → **その secret を使う unit を restart**
  (secret を替えただけでは動いているコンテナに届かない)。回転の手順は別の節にまとめる(実装時)。
- `ERLANG_COOKIE` が既定値だと gateway は起動を断る(安全のため。OPS_DEPLOY.md §1.2)。
- バックアップ: `podman secret` の中身は `dtlv copy` の控えに入らない。秘密の控えは別の保管場所に(パスワードマネージャ等)。

## 7. データの形が変わる版

image を戻しても、**書き込まれたデータは戻らない**(SERVER_SHELL.md §5.6)。Datalevin はスキーマが「開くときに入る」ので、
新しい版で開いたあとに古い版で開けるかは、スキーマ追加だけなら見込みがあるが**検証していない**。方針:

- bump PR に「データの形が変わる」印を付ける(CI が `priv/datalevin/catalog.exs` の差分から機械的に付ける)。
- 印のある PR は、同期スクリプトが **適用前に `dtlv copy` の控えを取る**(`infra/backup/sukhi-backup.sh` を呼ぶ。OPS_MAINTAIN.md §3)。
  控えが取れなければ**適用しない**。
- 印のある更新は、失敗しても**自動では戻さない**(止めて通知。人が控えから戻すか進めるかを決める)。
- 印のない更新は、§3.5 のとおり自動で戻す。

## 8. 利用者・管理者への見え方

- 適用の前に告知を出す仕組み(SERVER_SHELL.md §5.8 の告知 → カウントダウン)は、GitOps でも**同じ入口**を使う。
  bump PR のマージ → 箱が引く、の間に告知を挟むかは §12-9。最初は挟まず、gateway が短く止まることをメンテナンスの目安として書く。
- 同期の結果(適用した sha・時刻・失敗・`rejected`)は、journald と `state/history` に残し、管理画面の「いまのサーバー」に出す(後続)。

## 9. 更新ツール(Renovate / Dependabot)

調べた範囲(**公式ドキュメントの文面。実際に動かしてはいない**):

| | Quadlet の対応 | 根拠 |
| --- | --- | --- |
| **Renovate** | **ある。** `quadlet` マネージャ(カテゴリ docker)。既定で `*.container` `*.image` `*.volume` を見て、`Image=` を `docker` データソースで更新する | [Renovate: Quadlet manager](https://docs.renovatebot.com/modules/manager/quadlet/) |
| **Dependabot** | **見当たらない。** 対応表にあるのは docker(Dockerfile と Kubernetes マニフェスト)、docker-compose、helm、devcontainers などで、Quadlet / `.container` の記述は無い | [GitHub Docs: supported ecosystems](https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-repositories) |

Renovate についての注意(どれも**要確認**):

- 文書に**ドロップイン(`*.container.d/*.conf`)の言及が無い**。`Image=` は本体の `.container` に置き、ドロップインに逃がさない。
- **ダイジェストの固定(`pinDigests`)** は Renovate の docker データソース共通の機能だが、Quadlet マネージャで効くことは文書に書かれていない。試して確かめる。
- sukhi の image は `{{version}}` の形で Quadlet マネージャには読めない(§5)。`overlays/<env>/sukhi.version` は `bump-version.sh` で上げ、Renovate は第三者の image だけ。
- 向く相手: `nats:2-alpine`、Anubis の土台、その他の第三者 image。PR は sukhi-infra の同じ関所(§3.2)を通り、自動マージはしない。
- Dependabot は使えない前提で、sukhi-infra には入れない(`sukhi-fedi` 本体の npm / mix / Actions 用には従来どおり)。
- Renovate は GitHub App(Mend)か自前の実行のどちらか。`renovate.json` を deploy に置くだけで始まるのは App の場合。

## 10. 「main を信じる」ための守り

この設計は、**sukhi-infra の main に入ったものを箱が実行する**。main への書き込み権限が奪われれば、箱で動くものを選ばれてしまう。守りを何重かに置く:

| 層 | 守り |
| --- | --- |
| ブランチ保護 | main への直接 push 禁止、PR 必須、**必須レビュー 1 人以上**(PR の作者本人と bot は数えない)、必須チェック(§3.2)、force-push と削除の禁止、管理者にも適用(バイパス無し)、CODEOWNERS で `*.container` を指定 |
| コミット署名 | **署名つきコミットを必須**にし、箱は `git verify-commit` で検証してから適用する(§3.3-3)。公開鍵(`allowed_signers`)は**箱の上**に置き、リポジトリの中に置かない(リポジトリを書き換えた人が鍵も書き換えられるため) |
| image の署名 | main が何を指しても、各ダイジェストを cosign で検証する(§3.3-4)。**乗っ取られた main でも、こちらの workflow が焼いた image しか動かせない** |
| 権限の最小化 | CI の bot は PR を立てるだけ。箱は sukhi-infra を**読み取り専用の deploy key** で引く。箱から GitHub へ書かない |
| 巻き戻しの攻撃 | 古い(脆弱な)でも署名つきの image を指す commit は、署名検証だけでは弾けない。レビューで見る点として PR に前回との差(sha の新旧)を載せる。機械的に弾く(sha が新しい commit の子孫であること)は将来 |
| 箱の外の通知 | 適用・拒否・戻しを必ず通知する(見えない失敗を作らない) |

署名の方式は §12-5 で選ぶ(GitHub が付けるマージコミット署名の鍵を箱に固定する / 管理者の SSH 署名鍵)。

## 11. rootless と Cockpit

Cockpit の導入・127.0.0.1 だけで待つ設定・SSH トンネル・ログインの注意は [`RUNTIME.md`](RUNTIME.md) §12.1 / §12.5 のとおり(決定済み)。
ここでは、**GitOps の箱として rootless と Cockpit を並べたときに効いてくること**だけを書く。すべて実機では未確認。

### 11.1 rootless の前提

- **`loginctl enable-linger sukhi`**: ログアウトしても user の systemd(と timer、コンテナ)が動き続ける。無いと再起動後に何も起きない。
- user の `systemctl` を ssh 越しに使うときは `XDG_RUNTIME_DIR=/run/user/$(id -u sukhi)` が要る(`su` ではなく直接 ssh、または `machinectl shell sukhi@`。OPS_UPDATE_QUADLET.md の `nounit` と同じ注意)。
- timer も service も **user unit**(`~sukhi/.config/systemd/user/`)。root の cron や system の timer に逃がさない。
- Quadlet は `~sukhi/.config/containers/systemd/` を見る。チェックアウトをそこに置かず、同期スクリプトが **重ねて書き出す**(§1.1)。
  書き出しは一時のディレクトリに作ってから入れ替える(途中の半端な状態を Quadlet に読ませない)。
  (root が `/etc/containers/systemd/users/<UID>/` に置く道もあるが、同期を root にしたくないので使わない。)
- **subuid / subgid**: `useradd` が `/etc/subuid` `/etc/subgid` に範囲を付ける。`grep sukhi /etc/subuid /etc/subgid` で確かめる(setup の準備に入れる)。
- **ポートは 1024 以上**: Anubis は `PublishPort=127.0.0.1:8080:8080`、ホストの nginx が受ける。rootless のネットワーク(pasta)越しだと、
  コンテナから見た送信元は nginx(ホスト)になる。**利用者の IP は nginx が付ける `X-Forwarded-For` で受ける**(おいた枠・レート制限が IP で数えるときの前提。rate-limit の記録と同じ注意)。
- **ボリュームの持ち主**: コンテナ内の root は、ホストでは `sukhi` に写る。`sukhi-data.volume` + `:Z` なら通る見込みだが、
  非 root で動く image(web-*)に bind mount を足すときは `UserNS=keep-id` などが要るかもしれない。Datalevin の書き込みで確かめる。
- **cgroup の委譲(重要)**: rootless は、systemd が cgroup を `sukhi` に**委譲**した分しか制限できない。Rocky 9 の既定は memory / pids までで、
  **cpu は既定では委譲されない**ことが多い。`MemoryMax` は効いても `CPUWeight=` / `CPUQuota=` が黙って効かない可能性がある。
  0.5 OCPU の箱で `cpu.weight` を試す予定(TODO.md)なので、setup に次を入れて確かめる:
  ```ini
  # /etc/systemd/system/user@.service.d/delegate.conf (root が置く。setup の準備)
  [Service]
  Delegate=cpu cpuset io memory pids
  ```
  確かめ方: `cat /sys/fs/cgroup/user.slice/user-$(id -u sukhi).slice/user@$(id -u sukhi).service/cgroup.controllers`(`cpu` が出ること)。
- **SELinux**: Rocky は有効が既定。bind mount とボリュームに `:Z`。`container-selinux` が入っていること。ラベルの問題は `ausearch -m avc -ts recent` で見る。
- **`podman secret`(rootless)**: 既定の保管は `~sukhi/.local/share/containers/storage/secrets/` の**平文のファイル**(権限 600)。
  暗号化されない。ディスクの控えに入れるときの扱いに注意(§6)。
- **image の置き場**: rootless の image は `~sukhi/.local/share/containers/storage/`。小さな箱ではここがディスクを食う。
  古い image の掃除は `podman image prune` でなく、last-good と一つ前のダイジェストを残して消す(戻すため)。
- ヘルスチェックは podman が systemd の一時 timer で回す。user の systemd が生きていること(= linger)が前提。
- `podman-auto-update.timer`(user)は有効にしない(§14)。

### 11.2 Cockpit と GitOps(「見る」と「変える」を分ける)

- 見る相手は**専用ユーザー `sukhi` でログイン**した Cockpit(rootless のコンテナは、そのユーザーでだけ見える。RUNTIME.md §12.1)。
  cockpit-podman でコンテナ・image・ログ、Services で user の unit と timer の状態が見える(user の unit の出し方は版で違う。**要確認**)。
- **Cockpit は「見る」だけに使う方針を推奨する。** 変える道を二つ持つと、git の外の状態ができる:
  | Cockpit で出来てしまうこと | 起きること | 方針 |
  | --- | --- | --- |
  | unit の停止・再起動 | 次の同期は、変わっていない unit を触らないので、**止めたままになる** | 一時の切り分けには使ってよい。戻すのを忘れない(同期は「止まっている unit」を通知する) |
  | コンテナの削除 | Quadlet の unit が起こし直す(同じ image) | 実害は小さい |
  | image の pull / 新しいコンテナの作成 | Quadlet の外のコンテナができる(名前・ポートが衝突しうる) | **しない**。image は git のダイジェストだけ |
  | 画面で環境変数や image を変えた「再作成」 | Quadlet の定義と食い違う | **しない**。変更は `sukhi-infra` の PR |
- ログ: `LogDriver=journald` なので、Cockpit の Logs / `journalctl --user -u sukhi-gateway` で同じものが見える。
  user の journal を読めるように、`/var/log/journal` を作って永続化し、`sukhi` が読める権限(`systemd-journal` グループなど)にする(setup の準備)。
  同期の結果(`sukhi-gitops-sync`)も同じ journal に出る(§3.3)。
- 同期の状態(last-good / rejected)を Cockpit から読みやすくするため、同期スクリプトは**一行で足りる要約**を journal の最後に出す
  (例: `sync ok sha-abc1234 (gateway,web-next restarted)` / `sync rejected sha-def5678: healthcheck gateway`)。
- 9090 番は 127.0.0.1 のまま・SSH トンネル経由(RUNTIME.md §12.5)。**Cockpit の `sukhi` ログインは、箱の中で `sukhi` の権限を丸ごと渡す**
  (= Quadlet・secret・Datalevin のデータに触れる)ので、強いパスワード + トンネルの中だけ、を崩さない。
  `sukhi` を ssh の鍵だけで入るユーザーにしている場合、Cockpit 用にパスワードを別に持つかは §12-11。

## 12. 決めてほしいこと(選択肢と推奨)

1. ~~Quadlet の正本の置き場所。~~ **決定済み(ひなた, 2026-11-01): `sukhi-infra`(Quadlet)+ `sukhi-setup`(準備と同期スクリプト)。** 理由は §1。
2. **箱が引く(pull timer)か、CI が箱に入る(push, SSH)か。**
   推奨は pull。CI が箱の鍵を持たない。push は反応が速いが、鍵と箱の入口を CI に渡すことになる(`sukhi release --now` で「待たずに一回」は pull のまま足せる)。
3. **bump PR の承認。** 推奨は**当面すべて人が承認**(自動マージ無し)。安定して、署名・ヘルス・戻しが信頼できると分かったら、
   「データの形が変わらない・パッチだけ・夜間の窓」に限って自動マージを検討(SERVER_SHELL.md §5.8 末尾と同じ順序)。
4. **自動で戻す範囲。** 推奨は image と unit だけ(§3.5、§7)。データの形が変わる版は止めて人に渡す。
5. **コミット署名の方式。** (a) GitHub のマージコミットの署名鍵を箱に固定(推奨: マージ操作だけで署名が付く。GitHub に依存する) /
   (b) 管理者の SSH 署名鍵(GitHub に依存しない。マージの手が一つ増える)。
6. **箱の Podman の版。** Rocky のリリースと `podman --version` を教えてほしい。`Notify=healthy` / `HealthOnFailure=` / ドロップイン / `Secret=` の書式は、
   版で変わる。版が古ければ §4 の案を一部落とす(ヘルス待ちを同期スクリプトの polling に戻す)。
7. **web-board(natadeco)を同じ箱で動かすか。** 動かすなら unit を足す。別の箱なら、箱ごとの overlay(`overlays/<host>/`)に分ける。
8. **深いヘルスの口。** `/up`(BEAM が答える)で始めてよいか。DB とキューまで見る口(`/up?deep=1` など)を足すなら別の作業にする。
9. **適用前の告知。** 最初は告知なし(短い断の目安を書く)でよいか。入れるなら bump の承認から適用まで(5 分)に挟むか。
10. **通知の先。** journald のほかに、どこに出すか(管理画面のお知らせ / Matrix / ntfy など)。
11. ~~Cockpit の使い方。~~ **決定済み(ひなた, 2026-11-01): `sukhi` ユーザーのパスワードは Cockpit に必須。パスワードマネージャーで生成して設定する。** Cockpit は「見る」だけに使う(§11.2)。
12. ~~cgroup の委譲。~~ **決定済み(同上): setup に `Delegate=cpu cpuset io memory pids` を入れる**(`sukhi-setup/systemd/system/user@.service.d/delegate.conf`)。

## 13. 段階的な導入(提案)

| 段階 | 内容 | 確かめること |
| --- | --- | --- |
| 0 | いまの手作業(`sukhi-swap-image.sh`)で Quadlet の箱を一度動かす。**ここで実機の未確認を潰す** | OPS_UPDATE_QUADLET.md §6 の未確認、Podman の版(§12-6) |
| 1 | `sukhi-infra` に §1.1 の base を置き(`sukhi-setup` に準備の手順)、§2 の unit を置く(compose から `podlet` で下書き → 手で直す)。手で `daemon-reload` して起動 | ヘルス(`wget`)、`Notify=healthy`、`podman secret` の事前作成、`enable-linger` |
| 2 | 同期スクリプトを **`--check`(計画だけ、変更しない)** で timer に載せる | 差分 → 変わる unit の求め方、署名検証、ログの読みやすさ |
| 3 | 適用を有効にする(承認はまだ全部人)。失敗の戻しを**わざと壊した PR で**試す | §3.5 の reset とヘルス待ち、`rejected` が効くこと |
| 4 | リリース / main の最後に `bump-version.sh` を回して PR を立てる CI | 5 つが同じ版で揃うこと、解決に失敗したら何も書かないこと |
| 5 | Renovate を第三者 image に(`pinDigests` を確かめる) | §9 の要確認 |

## 14. 今は決めない・やらないこと

- Kubernetes・Flux・Argo CD(この箱には重い。考え方だけ参考。SERVER_SHELL.md §5.9)。
- `AutoUpdate=registry` / `podman-auto-update.timer`(署名を見ない)。
- 複数台・ブルーグリーン(Datalevin の書き手が一つ)。
- Compose 版の置き換え(Docker を使う人と開発用に残す。RUNTIME.md §13-10)。
