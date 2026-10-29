<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# 配信キューを Postgres から SQLite に移す

`DELIVERY_QUEUE=sqlite` に切り替えるときの手順です。環境変数は `docs/ENV.md` を見てください。
**切り替え時点で Postgres の `oban_jobs` に残っているジョブは、手順 B の自動移管が SQLite に移します。**
これがないと、`outbox_dispatch` は切り替え後に Postgres 側で処理されなくなり、残ったジョブを誰も実行しません。
そこで、先に空にしてから切り替える（手順 A）か、残りを移す（手順 B、起動時に自動）かのどちらか、あるいは両方（A のあとに B）にします。

## 何が残りうるか

| 場所 | 切り替え後の扱い |
|---|---|
| `outbox` の `pending` 行 | 問題なし。リレーが SQLite に積む |
| `oban_jobs` の `outbox_dispatch`（`available`/`scheduled`/`retryable`/`executing`） | **処理されない**。先に空にするか、移す |
| `oban_jobs` の `delivery` | 問題なし。Postgres 側でも処理し続ける（ゲートウェイ単独ノードが積む分があるため） |
| `federation` / `push` / cron | 変わらず Postgres |

## 手順 A: 受け入れを止めて、空にしてから切り替える（コード変更なし）

1. 受け入れを止める。プロキシ側で `POST /users/*/inbox`・`/inbox` と書き込み系 `/api/*` を 503 にする。
   アプリ内に保守モードはまだありません。
2. 新しい outbox 行が増えなくなったら、リレーが全部流すのを待つ。
   `SELECT count(*) FROM outbox WHERE status = 'pending';` が 0 になれば完了。
3. 配信ジョブが終わるのを待つ。
   ```sql
   SELECT queue, state, count(*) FROM oban_jobs
   WHERE queue IN ('delivery', 'outbox_dispatch')
     AND state IN ('available', 'scheduled', 'executing', 'retryable')
   GROUP BY 1, 2;
   ```
   `outbox_dispatch` が 0 になるまで待つのが必須。`delivery` の `retryable` は、相手サーバーが落ちていると何時間も残る。
   これは待たずに切り替えてよい（Postgres 側が処理を続ける）。
4. `DELIVERY_QUEUE=sqlite` と `DELIVERY_QUEUE_DB`（ディレクトリは先に作る）を設定して delivery を再起動する。
   初回起動で SQLite のテーブルが自動で作られる。
5. 受け入れを再開する。ログに `Exqlite … failed to connect` が出ないこと、
   新しい投稿が SQLite の `oban_jobs`（`available`→`completed`）に流れることを確かめる。

止める時間は、`outbox_dispatch` を空にするまでの数十秒〜数分です。

## 手順 B: 残りを自動で SQLite に移す（実装済み）

`DELIVERY_QUEUE=sqlite` で起動すると、`SukhiDelivery.Queue.Handover` が一度だけ走ります（`DELIVERY_QUEUE_HANDOVER=0` で止められます）。
SQLite のテーブルを作った直後、Postgres 側の Oban が動き出す前に、次のことをします。

- `delivery` / `outbox_dispatch` の `available`・`scheduled`・`retryable`・`executing` を SQLite へ移す。
  `worker`・`args`・`attempt`・`max_attempts`・`scheduled_at`・`errors` はそのまま。
- `executing` は、切り替えのために止めた旧プロセスの置き土産なので、`available` に戻し、`attempt` を 1 戻す（Lifeline と同じ扱い）。
- 終わったジョブ（`completed`/`discarded`/`cancelled`）は動かさない。
- **SQLite に入れてから Postgres の行を消す。** 途中で落ちたら二重になりうるが、失うことはない。
  重複は `delivery_receipts`（配信）と `outbox_id` の確認（リレー）が吸収する。
- 失敗してもログに出して起動は続ける。行は Postgres に残り、次の起動でもう一度試す。
  もう一度走らせても、移した分は Postgres にないので何も起きない。
- 前提は単一ノードであること。別ノードがまだ同じジョブを実行していると、二重実行になりうる。

## A のあとに B（推奨の流れ）

1. 受け入れを止める（手順 A の 1）。
2. リレーが `outbox` の `pending` を流し切るのを待つ（手順 A の 2）。ここで新しい投稿の分が Postgres の `outbox_dispatch` に出そろう。
3. `DELIVERY_QUEUE=sqlite` で再起動する。Handover が `outbox_dispatch` と残りの `delivery` を SQLite に移す。
   `outbox_dispatch` が空になるのを待つ必要はない。
4. ログに `Queue.Handover moved N job(s)` が出て、`SELECT count(*) FROM oban_jobs WHERE queue = 'outbox_dispatch' AND state IN ('available','scheduled','retryable','executing')`（Postgres）が 0 なのを確かめて、受け入れを再開する。

受け入れを止める時間は、リレーが流す数秒〜数十秒と再起動の分だけです。

## 戻す

`DELIVERY_QUEUE` を外して再起動すれば、リレーとゲートウェイは Postgres に積みます。
SQLite に残ったジョブは Postgres から見えないので、戻す前に手順 A と同じ要領で SQLite 側を空にします。
（SQLite → Postgres の自動移管も、手順 B の逆向きで同様に書けますが、まだありません。）

## 切り替え後に確かめること

- ゲートウェイを同じプロセスで動かす combined リリースでは、配信状況と失敗件数が SQLite も合算して表示される。
  別ノードのゲートウェイは SQLite を読めないので、そちらの表示は Postgres 側の分だけになる。
- `DELIVERY_QUEUE_SYNCHRONOUS` は既定の `full`。`normal` は速いが、停電で直近のコミットを失いうる。
- SQLite のファイルは 1 台専用。複数ノードで共有しない。バックアップは `sqlite3 <file> ".backup <dest>"` で取る。
