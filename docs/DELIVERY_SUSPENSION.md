<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# 配送のお休み(FEP-f799)

**意図:** 相手のサーバーが「いまメンテナンス中です」と告げたとき、その間は送らずに待ち、明けたらそっと送り直す。
**読む人の困りごと(仮説):** 相手が止まっている間に、こちらの配送が失敗を重ねて諦めてしまうこと。また、だれかが他人の宛先を「お休み」にして、配送を止められてしまうこと。

> FEP-f799 は DRAFT です。プロパティ名は変わるかもしれないので、名前は `SukhiShared.DeliverySuspension.Notice` の一か所にまとめてあります。
> 見通しと段ごとの計画は #116(子 issue #156〜#162)。配送を休ませる道は通っていますが、**お知らせを有効にする制御の確認が段4なので、実際に休む配送はまだありません**(下の「いまどこまで」)。

## 守っている約束

- **迷ったら、ふつうに配送する。** 偽の通知でも、読めない通知でも、配送が止まる方向には働かない。
- **お休みは延びない。** 実効終了は `endTime`・署名の期限・`published` + 年齢上限・開始 + 最長時間の一番早い時刻で、再取得や再配信では延びない。
- **取り消しは最終。** `Undo`・`status: cancelled`・それを運ぶ `Update` は revision に関係なく有効で、あとから高い revision の `active` が来ても復活しない。新しいお休みには新しい ID を使う。
- **本物かを、持ち主に対して確かめる。** お知らせ自体の proof は、鍵の持ち主が `attributedTo` かを比べる(`Oip.verify_inbound/3` の `owner:`)。比べる相手を渡さないと「だれの鍵でもよい」になる。
- **制御の確認ができるまで、受けない。** 宛先を告げる権利(その inbox / origin を本当に管理しているか)の確認は段4。それまで `Control.verify/2` は常に「確認できない」と答えるので、受け取りの道はあるが、お知らせは1件も有効にならない。

## 対応する構成

- **Datalevin の combined だけ。Postgres 構成は f799 に対応しません**(受け取った記録の置き場が `schema.edn` で、Postgres の migration には無い)。
- 記録は graph ストア(`SUKHI_GRAPH=1`、`docker-compose.datalevin.yml` では既定で 1)に置く。graph が無いとき、お知らせは通常の受信と同じ道を通り、何も起きない。

## 受け取り(段2)

`AP.Ingest.run/3` の、方針と proof のあと・`fedify.inbox.v1` の分類の前に分岐があります。`Create` / `Update` で `object` が `DeliverySuspension`、または `Undo` で指す `Create` がそうなら `Receiver` が引き受けます。ほかは今までどおり。

`Receiver`(`Fedi.DeliverySuspension.Receiver`)の順番は、軽いものから:

1. 本文の大きさ(64 KiB)と入れ子(8)
2. 送ってきた署名の host が actor の host と同じ。お知らせに proof があれば `attributedTo` に対して確かめる
3. activity の `id`・お知らせの `id`・`announcement` が controller の origin のもの
4. 形(`Notice.parse/2`)
5. 制御の確認(**始める・延ばす**ときだけ。取り消しや短くする更新では再確認しない)
6. 新しさ(未来すぎない、年齢上限、controller の cutoff)
7. 既知のものとの比較(不変項目、最高の revision、同じ revision で中身が違えば不正、同じ中身は何もしない)
8. 書いてから返す

`Undo` が `Create` より先に届いたら `(actor, create_id)` で預かり(actor ごとに16件、全体で4096件、年齢上限まで)、`Create` が届いたら、有効にする前に取り消しを当てます。

送り手への答えは、受理なら 202、拒否なら 400(本文は `delivery_suspension_rejected` だけ)。理由は telemetry `[:sukhi_fedi, :delivery_suspension, :received]` の `detail` と、info ログに出ます。

## 配送のとき(段3)

`SukhiDelivery.Delivery.Worker.perform` は、`already_delivered?` のあと・`UrlGuard.safe?` の前で `Worker.suspension_hold/4` を見ます。

- 休み中なら `{:snooze, 秒}`。秒は**実効終了 + 0〜60 秒のランダム**。ばらつきは、止めていた配送がいっせいに起きないためです。
- snooze は試行に数えません(Oban の Lite エンジンは `attempt` を1戻します。`delivery/test/queue/sqlite_queue_test.exs` で、すでに3回失敗したジョブでも `attempt` が3のままなのを確かめてあります)。バックオフと `max_attempts` の歯止めは、休む前と同じ場所にあります。`Retry-After` には触れません。
- 起きるたびにもう一度ゲートで見るので、休みのあいだに取り消されたら、そのまま送ります。
- **止めないもの**: `Create` / `Update` の `object` が `DeliverySuspension`、`Undo` が指す `Create` がそうなもの。型ではなく**中身**で見分けます(`Gate.exempt?/1`)。ふつうの `Create` / `Update` / `Undo` は止めます。
- 共有 inbox と個別 inbox は、休みを避けるために入れ替えません。宛てられた先に出します。
- 宛先の記録は ETS(`SukhiShared.DeliverySuspension.Cache`)の写しを引きます。**写しは正本ではありません**。gateway が store に書いたあとに写しへ入れ、起動時に `Upkeep` が store から組み直します。再起動しても、同じ宛先が同じ時刻まで休みます。取り消しは写しから消えます。
- **同じ VM のとき(combined)だけ働きます。** 写しの表は gateway が持つので、gateway と delivery が別の VM のとき、delivery には表が無く、何も休みません(迷ったら配送)。
- 休ませた件数は telemetry `[:sukhi_delivery, :suspension, :held]`。

## 記録するもの(`schema.edn`)

| 表 | 属性 | 中身 |
| --- | --- | --- |
| notices | `dsnotice/*` | お知らせごとに1行。`record` が JSON の全体(読み戻しの正本)。取り消しの行は「終わりの印」として残る |
| pending cancellations | `dspending/*` | 先に届いた Undo。`(actor, create_id)` で一意 |
| control evidence | `dsevidence/*` | 制御を最後に確認できた時刻と最後の試行(段4が書く) |
| controller cutoffs | `dscutoff/*` | 「この時刻より前は受けない」線 |

忘れるとき(`Store.sweep/2`)は、年齢上限を過ぎた notice と期限切れの預かりを消し、消した分だけ cutoff を進めます。方針をゆるめても、忘れた取り消しが蘇りません。`Upkeep` が1時間ごとに `sweep` を呼び、そのあと写しを組み直します。

## いまどこまで

| 段 | 中身 | 状態 |
| --- | --- | --- |
| 0 | 前提の補強(IPv6、DNS の固定、JSON の深さ) | merge 済み(#163) |
| 1 | 純粋な部品 `Origin` `Notice` `Policy` `Gate` | merge 済み(#165) |
| 2 | `Store`・`Receiver`・`Ingest` の分岐・proof の持ち主 | merge 済み(#167) |
| 3 | 配送への組み込み(保留・免除・再開・ETS) | この変更 |
| 4 以降 | 取得と制御の確認、告げる側、管理画面 | 後 |

初版の範囲は段0〜3。宛先ごとの同時数、容量上限の記録、`Retry-After` は後回しです。
