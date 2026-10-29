<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# 配信キューを Postgres から SQLite に移す

`DELIVERY_QUEUE=sqlite` に切り替えるときの手順です。環境変数は `docs/ENV.md` を見てください。
**切り替えそのものは再起動だけで済みますが、切り替え時点で Postgres の `oban_jobs` に残っているジョブは自動では移りません。**
`outbox_dispatch` は切り替え後に Postgres 側では処理されなくなるので、残ったままだと誰も実行しません。
そこで、先に空にしてから切り替える（手順 A）か、残りを移してから切り替える（手順 B）かのどちらかにします。

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

## 手順 B: 残りを自動で SQLite に移す（**未実装**）

受け入れを止める時間を最小にしたい場合の設計です。まだ書いていません。

1. 切り替えの再起動の前に、受け入れを止める（手順 A の 1 と同じ）。
2. `executing` が 0 になるまで少し待つ（実行中のジョブは移さない）。
3. リリース関数 `SukhiDelivery.Queue.Handover.run/0` を実行する。
   - Postgres から `queue IN ('delivery','outbox_dispatch') AND state IN ('available','scheduled','retryable')` を読む。
   - 各ジョブを同じ `worker`・`args`・`queue`・`attempt`・`max_attempts`・`scheduled_at`・`errors` のまま SQLite に挿入する。
   - **挿入が済んでから**、Postgres の該当行を消す。途中で落ちると二重になりうるが、
     `Delivery.Worker` は `delivery_receipts` で、`DispatchWorker` は `outbox_id` で重複を吸収する。ジョブを失うよりこちらを選ぶ。
   - 何件移したかを返す。もう一度実行しても、移した分は Postgres にないので何も起きない。
4. `DELIVERY_QUEUE=sqlite` で再起動し、受け入れを再開する。

受け入れを止める時間は、再起動と移管の数秒〜数十秒に縮みます。`delivery` の `retryable` も新しい側に集まります。

## 戻す

`DELIVERY_QUEUE` を外して再起動すれば、リレーとゲートウェイは Postgres に積みます。
SQLite に残ったジョブは Postgres から見えないので、戻す前に手順 A と同じ要領で SQLite 側を空にします。
（SQLite → Postgres の自動移管も、手順 B の逆向きで同様に書けますが、まだありません。）

## 切り替え後に確かめること

- ゲートウェイを同じプロセスで動かす combined リリースでは、配信状況と失敗件数が SQLite も合算して表示される。
  別ノードのゲートウェイは SQLite を読めないので、そちらの表示は Postgres 側の分だけになる。
- `DELIVERY_QUEUE_SYNCHRONOUS` は既定の `full`。`normal` は速いが、停電で直近のコミットを失いうる。
- SQLite のファイルは 1 台専用。複数ノードで共有しない。バックアップは `sqlite3 <file> ".backup <dest>"` で取る。
