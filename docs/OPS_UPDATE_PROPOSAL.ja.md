<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# 管理画面に「更新が来ています」を出す(設計案)

> 設計の案。実装はまだない。土台は [OPS_QUADLET_GITOPS.md](OPS_QUADLET_GITOPS.md)(箱の同期ツール `sukhi-gitops-sync`)と、
> sukhi-setup / sukhi-infra の現行の形(2026-11-05)。

## 0. 一言で

新しい版が来たことと、箱の更新が止まっていることに、**管理画面で気づけるようにする**。
続けて、**管理画面の「承認」ボタンで、その版を箱に入れられるようにする**(段階 2。早めに続ける)。
止まったときと新しい版が来たときは、**管理者に Web Push でも知らせる**(§7)。マージは人がする。

いまは、同期ツールが失敗しても、新しい版が来ても、箱に入って `sukhi-gitops-sync status` を見るまで分からない。
journal は sukhi に読めず、通知(`NOTIFY_CMD`)も未設定だから。

## 1. 守る線

- **gateway(コンテナ)に、箱を動かす手を渡さない。** podman のソケットも、systemd への道も渡さない。cap を落とした rootless のまま。
- 管理画面でできるのは、「この sha を入れていい」という**印を置く**ことだけ。入れる側(箱の systemd)が、印と**自分の検証**の両方を見て動く。
- 管理者の画面が乗っ取られても、任意のものは入らない。早められるのは、**署名と cosign の検証を通った版の適用の時機**だけ。

## 2. 段階 1: 見せるだけ

### 2.1 箱: 状態を書く

`sukhi-gitops-sync` は `--check` / `--apply` のたびに、`$STATE_DIR/public/status.json` を**原子的に**(tmp → rename)書く。
秘密や unit の中身は入れない。gateway が読むのはこのディレクトリだけ。

```json
{
  "schema": 1,
  "env": "dev",
  "checked_at": "2026-11-05T04:50:00Z",
  "applied": { "commit": "09810f454aef…", "version": "sha-a81329d", "at": "2026-11-05T03:20:38Z" },
  "available": { "commit": "ab12cd34ef56…", "version": "sha-3f9e0a1", "verified": true },
  "state": "update_available",
  "rejected": [],
  "last_error": null
}
```

- `state`: `up_to_date` / `update_available` / `rejected`(適用に失敗して見送り中)/ `error`(fetch・検証の失敗)/ `stale`(下記)
- `available` は**検証済みのものだけ**(署名・cosign を通った後)。通らなかったときは `last_error` に一行(例: `commit has no valid gpg signature`)。
- `checked_at` が古い(timer が止まっている)ことは、読む側が `stale` と見せる。しきい値は timer 間隔の 3 倍。

### 2.2 gateway: 読んで見せる

- 箱の `…/sukhi-gitops/public` を、gateway に `:ro` で載せる(infra の base ではなく overlay の drop-in。`Volume=…/public:/run/sukhi-gitops:ro`)。
- `/admin/system`(既存の画面)に「更新」の節を足す。`status.json` が無い・読めないときは、節ごと出さない(dev のローカルで壊れないように)。
- 出すもの: いまの版、来ている版、状態、最後に確かめた時刻。`rejected` と `error` と `stale` は目立たせる。
- 版へのリンクは、sukhi-fedi の該当コミットと、infra の bump の PR。承認は §3 までは GitHub 側。

## 3. 段階 2: 画面から承認する

### 3.1 流れ

```
管理画面 [承認] ─ approve.json を書く ─▶ 箱の path unit が検知
                                          └▶ sukhi-gitops-sync --apply --approved
                                               ・origin/main を fetch、署名 / cosign を検証(通常と同じ)
                                               ・approve.json の commit == 今の検証済みの target か確かめる
                                               ・適用 → ヘルス → 成功/失敗を status.json と history に
                                               ・approve.json を消す
```

- timer は **`--check` のまま**回る(提案を作る係)。`--apply` は承認があったときだけ走る。
- `approve.json`: `{ "commit": "<40桁>", "by": "<管理者の acct>", "at": "<時刻>" }`。置き場は gateway だけが書ける、**別の**ディレクトリ(`/run/user/<uid>/sukhi-approve`、`:rw`)。status の `public` とは分ける。
- 承認が使えるのは **1 時間**。それを過ぎた、または `commit` が今の target と違う(その間に新しい版が来た)ときは、使わずに捨てて、画面に「もう一度確かめてください」と出す。
- 同時に二度走らない(同期ツールの lock を使う)。

### 3.2 ボタンの守り

- 既存の管理画面の認可(`is_admin` のベアラー、毎回再検証)に載せる。POST は既存の管理 POST と同じ作法(CSRF の扱いも合わせる)。
- 押したら `admin_audit` に残す(`who` / `what=update_approve` / `commit`)。同期ツール側の `history` にも承認者を一行足す。
- 確認の文面に、**版と変更の一覧へのリンク**を出す。「アプデする?」と訊く以上、何が変わるかを見せる。
- 戻しのボタンは、この設計には含めない(別の話。まず適用の失敗時の自動の戻し=既存の仕組みを信じる)。

### 3.3 承認は二つ、役目を分ける

人がする関所は二つ残す(2026-11-05 に決まった)。

- **infra の bump PR をマージする = 「この版を入れてよい」。** PR は自動で出るが、**マージは人がする**(自動マージはしない)。
- **管理画面の承認 = 「いま入れる」。** マージされた版に対して、入れる時機を決める。

マージ前の版は「更新が来ています」に出ない(`available` は、infra の main に入った、検証済みのものだけ)。

## 4. 箱側の変更(sukhi-setup)

- `bin/sukhi-gitops-sync`: `status.json` を書く(2.1)、`--approved`(3.1)。`--approved` は `approve.json` を**検証の後**にだけ見る。順序を変えない。
- `systemd/user/`: `sukhi-gitops-approve.path`(`PathChanged=` で approve.json を見る)と `sukhi-gitops-approve.service`(`--apply --approved`)。`prepare-user.sh` が入れる。
- `test/sync_test.rb`: status の各 `state`、承認の期限切れ・commit 違い・検証失敗の三つ、lock の競合。
- PREPARE.md に、新しい unit の節と、`public` / `approve` ディレクトリの権限(sukhi 持ち、gateway からは `public` が ro、`approve` が rw)。

## 5. 決まったことと、残り

決まった(2026-11-05):

1. **マージは人がする。** bump PR は自動で出し、マージは人。承認は二つで、役目を分ける(§3.3)。
2. **提案を出す側:** sukhi-fedi の main への push から、infra の bump-dev を動かす(2c)。まとめる間隔は 2c で決める(例: 1 時間に 1 本まで)。
3. **通知は push。** 管理者(`is_admin`)に Web Push を送る(§7)。
4. **ローカル開発:** `status.json` が無い環境では、画面の節を出さない。

残り:

- 公開後(prod)の承認の置き方(prod は semver のリリースで、dev とは流れが違う)。
- 自動の bump PR の本数と、まとめる間隔(2c で決める)。

## 6. 段階

| 段階 | 中身 | 触る場所 |
|---|---|---|
| 1a | `status.json` を書く | sukhi-setup |
| 1b | `/admin/system` に「更新」の節 | sukhi-fedi + infra の drop-in(ro 載せ) |
| 2a | `approve.json` の流れ、path unit、`--approved` | sukhi-setup |
| 2b | 管理画面の承認ボタン、`admin_audit` | sukhi-fedi + infra の drop-in(rw 載せ) |
| 2c | 自動の bump PR(マージは人)。sukhi-fedi の main の push から | sukhi-infra、sukhi-fedi の workflow |
| 3 | 管理者への push(§7) | sukhi-fedi(`web_push` と通知の型) |

1a と 1b が出たら、2a と 2b を続けて出す。2c と 3 は、そのあとに続ける。


## 7. 管理者への push

画面は開いたときにしか気づけない。止まったこと・新しい版が来たことを、管理者(`is_admin`)の端末に Web Push で知らせる。

### 7.1 静かな約束を崩さない

アプリの Web Push は、`direct`(`mention` / `follow_request`)だけが人を起こせる(`WebPush.deliverable?/3` が唯一の入口。[WEBPUSH.md](WEBPUSH.md))。
運用の知らせは**別の枠(operator)**として、同じ入口の中に足す。入口を増やさない。

- `operator` の型(例: `system_update`)は、**`is_admin` の購読にだけ**届く。利用者には届かない。
- 静かな時間(`quiet_until`)と、購読ごとの有効/無効は、いままでどおり効く。
- 型の一覧は、Elixir と web-next で同じ元から作る(いまの `direct_types` と同じ約束)。

### 7.2 いつ送るか

送るのは**状態が変わったとき、一度だけ**。同じ内容を繰り返さない(`state` と `commit` の組で重複を切る)。

| 状態の変わり目 | 文面の例 | 急ぎ |
|---|---|---|
| `update_available`(新しい版がマージされた) | 「更新が来ています: sha-3f9e0a1」 | 普通 |
| `rejected`(適用に失敗して見送り) | 「更新を見送りました。前の版に戻っています」 | 高い |
| `error`(fetch・検証の失敗が続く) | 「更新の確認で失敗しています」 | 高い |
| `stale`(確認が止まっている) | 「更新の確認が止まっています」 | 高い |
| 承認で適用に成功 | (送らない。画面で見える) | — |

### 7.3 誰が見て、誰が送るか

- gateway が `status.json` を定期に(1 分程度)読み、状態の変わり目を見つけて送る。箱の側には送る手を持たせない。
- 管理者の送り先は、管理者アカウント(いまの `kuro_admin` など)の Web Push 購読。名前は埋め込まず、`is_admin` で選ぶ。

### 7.4 限界

- **gateway が落ちているときは、push も出ない。** gateway 自体や箱全体の停止は、この仕組みでは知らせられない。外からの死活監視は別の話(`OPERATING_OVER_SSH.md` などの範囲)。
- 通知を許可していない端末には届かない。画面(§2.2)が正本で、push はその知らせ。
