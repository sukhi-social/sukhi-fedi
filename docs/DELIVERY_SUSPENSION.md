<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# 配送のお休み(FEP-f799)

**意図:** 相手のサーバーが「いまメンテナンス中です」と告げたとき、その間は送らずに待ち、明けたらそっと送り直す。
**読む人の困りごと(仮説):** 相手が止まっている間に、こちらの配送が失敗を重ねて諦めてしまうこと。また、だれかが他人の宛先を「お休み」にして、配送を止められてしまうこと。

> FEP-f799 は DRAFT です。プロパティ名は変わるかもしれないので、名前は `SukhiShared.DeliverySuspension.Notice` の一か所にまとめてあります。
> 見通しと段ごとの計画は #116(子 issue #156〜#162)。受け取り・制御の確認・配送の保留まで通っています。配送の応答の Link ヘッダーからの取得も通っています。告げる側(段5)は、作って署名して、ピアへ配り、眠っている間は nginx が静的に答えるところまで通っています(下の「告げる側」)(下の「いまどこまで」)。

## 守っている約束

- **迷ったら、ふつうに配送する。** 偽の通知でも、読めない通知でも、配送が止まる方向には働かない。
- **お休みは延びない。** 実効終了は `endTime`・署名の期限・`published` + 年齢上限・開始 + 最長時間の一番早い時刻で、再取得や再配信では延びない。
- **取り消しは最終。** `Undo`・`status: cancelled`・それを運ぶ `Update` は revision に関係なく有効で、あとから高い revision の `active` が来ても復活しない。新しいお休みには新しい ID を使う。
- **本物かを、持ち主に対して確かめる。** お知らせ自体の proof は、鍵の持ち主が `attributedTo` かを比べる(`Oip.verify_inbound/3` の `owner:`)。比べる相手を渡さないと「だれの鍵でもよい」になる。
- **制御の確認ができなければ、始めない・延ばさない。** 宛先を告げる権利(その inbox / origin を本当に管理しているか)は、お知らせ自身ではなく、**その場で新しく取った文書**で確かめる(下の「制御の確認」)。読めなかったときは、始める側にも延ばす側にも倒さない。

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

## 制御の確認(段4)

`Control.verify/3` が、お知らせの controller がその宛先のために話せるかを、**HTTPS でその場で読んだ文書だけ**で確かめます。お知らせの中身は証拠になりません。キャッシュも etag も使いません(`Fetch`)。

| 宛先 | 確かめること |
| --- | --- |
| 個別 inbox | controller の actor の `inbox` がその URL。inbox コレクションの `inboxOf` が controller |
| 共有 inbox | inbox コレクションの `deliveryController` が controller **ただ1人**。actor の `endpoints.sharedInbox` がその URL。`inboxOf` では代われない |
| origin | origin 自身への WebFinger(ポートも付けたまま、`resource` は origin)。`subject` がその origin、`deliveryController` の rel の link がちょうど1つでその href が controller、その actor の `controlledOrigin` に origin がある。`rel` を絞る問い合わせは信じず、links を1つずつ見る |

答えは3つに分かれます。

- `:ok` — 確認できた。
- `{:unlinked, 理由}` — 文書は読めて、つながりが無い。受け取るときは拒否、もう持っているお知らせなら**取り下げ**(下)。
- `{:unreachable, 理由}` — 読めなかった(タイムアウト、5xx、404/410、401/403、大きすぎる、JSON でない)。取り消しでも延長でもない。持っているお知らせは、自分の終わりまでそのまま。

読み取りは `Fetch`:HTTPS だけ(リダイレクトも1歩ずつ確かめ直す、最大3回)、署名なし、64 KiB・入れ子8・10秒。`UrlGuard` が見た公開アドレスに固定して繋ぎます。

失敗した相手は **30 秒は同じ宛先を聞き直しません**(`{:unreachable, :throttled}`)。お知らせの洪水が取得の洪水にならないためです。試行はすべて記録されます(最後に確認できた時刻、最後の試行、失敗の種類)。

### 取り下げと再確認

`Upkeep` は1時間ごとに `Recheck.run/2` を回します。いま効いているお知らせのうち、最後の試行から50分以上たったものを、もう一度 `Control` で見ます。

- `:ok` — 証拠を更新するだけ。お休みの終わりは動かない。
- つながりが無くなった — **取り下げ**。お知らせは store に残る(revision と不変項目を覚えておくため)けれど `accepted_at` が空になり、ゲートも写しも相手にしない。取り消しではないので、つながりが戻って同じ revision が届けば、ふつうの確認を通ってもう一度受かる(最初の開始時刻のまま)。
- 読めなかった — 記録するだけ。

## 応答の Link ヘッダー(段4の後半)

休んでいるサーバーは、配送への応答に `Link: <お知らせの URL>; rel="https://w3id.org/fep/f799#deliverySuspension"` を付けられます。これは**ヒントであって、権威ではありません**。「どこを見ればいいか」を教えるだけで、見つけたものは inbox に届いたお知らせと同じ `Receiver` が、同じように疑います。

- 配送ノード(`Delivery.Worker`)は、どの状態の応答でも(エラーでも)`Link` を見ます(`SukhiShared.DeliverySuspension.Hint`)。見るのは、その rel を持つ**最初**のリンクだけ。`https` で、2048 バイトまで、配送先として許せる形のホスト。それ以外はヒントではありません。
- 見つけたら、gateway の `suspension_hint` キューに、`SukhiFedi.Fedi.DeliverySuspension.Hint` のジョブを入れます(アーカイブと同じ、文字列でワーカーを名指す方法)。**同じ URL は10分に1回だけ**(unique)。毎回の応答に付ける相手でも、取りにいくのは1回です。いま走っている配送は、ヒントで何も変わりません。
- gateway の `Hint` は `Fetch` で読み(HTTPS・公開アドレス・64 KiB・入れ子8・10秒)、次を確かめてから `Receiver` に渡します。
  - 文書の `id` が Link の URL そのもの、かつ `DeliverySuspension`
  - リダイレクトで別の origin に出ていない
  - その host から配信されたものとして扱う。つまり `attributedTo` が同じ host にいて、お知らせの `id` も controller のもの。他人のお知らせを指させることはできない
  - 知らないお知らせは、`Control` が新しく読んで確認できるまで受けない。**ヒントだけでは何も休まない**
  - すでに持っているものとの比べ方はふつうと同じ(取り消しは最終、古い revision は無視、同じなら何もしない)
- 読めなかったとき(サーバーが落ちている、`unavailable`)は、3回まで間を置いて取り直します。読めて断ったとき(おかしな文書、確認できない)は取り直しません。
- graph が無いときは、ジョブは何もしません。

telemetry: `[:sukhi_delivery, :suspension, :hint]`(渡した)、`[:sukhi_fedi, :delivery_suspension, :hint]`(gateway で受けた結果)。

## 告げる側(段5の前半)

sukhi 自身がメンテナンスの前に「ちょっと休むね」を告げる側です。**作業の前に全部作って署名しておく**ので、眠っているあいだはアプリも秘密鍵もいりません。

```sh
mix sukhi.suspension.prepare --account ops --minutes 60 --out ./suspension \
  --summary "メンテナンスです。1時間ほど。" --url https://example.tld/status
```

`SukhiFedi.Fedi.DeliverySuspension.Publisher.prepare/1` が、次を作ります(書くだけで、送りも公開もしません)。

| ファイル | 中身 | いつ使うか |
| --- | --- | --- |
| `public/suspensions/<slug>.json` | お知らせ(revision 1、`active`)。署名つき | 眠っているあいだ読める場所に置く |
| `send/<slug>.create.json` | お知らせを運ぶ公開 `Create` ひとつ。中身はピアごとに変えない | 休み始めるときにピアへ送る |
| `held/<slug>.cancel.json` | **先に署名した取り消し**(同じお知らせ、revision を上げて `status: cancelled`) | 作業が終わるまで**公開しない** |
| `held/<slug>.undo.json` | `Create` を指す `Undo` | 終わったあとに送る |
| `public/control/<パス>.json` | **制御の文書**(下) | 眠っている間も答えられる場所に置く |

- `endTime` は、見込みの 1.5 倍(`--margin`)。ただし方針の最長(48 時間)は超えない。ピアは `endTime` で自分から手を放すので、作業が長引いても足りるし、早く終わったら取り消しで終える。
- 取り消しは最終です。revision に関係なく有効なので、お知らせを延ばしたあとでも、先に署名した取り消しがそのまま使えます(`Publisher.extend/3` と `update_activity/3`。延ばすのは `endTime` だけ。方針の最長を超えるものは作らない)。
- 書くのは、人が読む一行(`summary`、200字まで)と、状況のページ(`url`)だけ。私的な運用の詳細は載せません。
- 署名は `Oip.sign/4`(eddsa-jcs-2022)。**渡された鍵が、そのアクターが公開している鍵と同じか**を、公開側の値と照らしてから署名します(違えば何も作りません)。作ったお知らせは、ピアが読むのと同じ形(`Notice.parse/2`)で読み戻して、断られるものは出しません。
- テストでは、これを別の sukhi の `Receiver` に渡して受理されること、先着の `Undo` が預かられて後着の `Create` が復活しないこと、取り消しのあとに同じ `Create` を再送しても復活しないことを確かめています。

### 眠っている間も見える「制御の文書」

ピアは、お知らせを受けるときだけでなく、**効いている間も1時間ごとに**制御を読み直します(`Recheck`)。アプリが眠っていると、そのとき actor も inbox も WebFinger も答えられません。答えられないだけなら「読めなかった」で済みますが(お知らせはそのまま効く)、誤解のもとなので、必要な文書を先に作って静的に置きます(`Publisher.controls/2`)。

- 個別 inbox: actor(`inbox`)と、inbox のコレクション(`inboxOf`)
- 共有 inbox: actor(`endpoints.sharedInbox`)と、コレクション(`deliveryController`)。`--inbox-kind shared` 相当は `inbox_kind: :shared`
- origin: WebFinger(`subject` が origin、`deliveryController` の link がひとつ)と、actor(`controlledOrigin`)
- actor には `assertionMethod` の鍵も入れる(こちらの proof を、あとからでも確かめられるように)

載せるのは確認が読むメンバーと鍵だけです。眠っている間の代わりで、アプリが戻ったら本物の答えに戻ります。テストでは、これを**本物の `Control.verify/3`** に読ませて、3つの場合すべてで確認できることを見ています。

### 配る

```sh
# 休み始める(アプリを止める直前)
bin/sukhi_delivery rpc 'SukhiDelivery.Release.announce_suspension("/srv/sukhi/send/m1.create.json")'
# 終わったあと
bin/sukhi_delivery rpc 'SukhiDelivery.Release.announce_suspension("/srv/sukhi/held/m1.undo.json")'
```

`SukhiDelivery.Delivery.Announce` が、事前署名したアクティビティを**そのまま**、ピアごとに `Delivery.Worker` のジョブにします(中身は変えず、ピアの一覧は載せない)。

- ピアは、すでにやりとりしている**リモートのホストごとに1つ**の inbox(自分の host は除く)。`:inboxes` で指定もできる。
- 時刻は `SukhiShared.DeliverySuspension.Spread.schedule/2`。順番はランダム、1つのピアにつき1つの枠、1秒に始まるのは `per_second + 1` 通まで(既定5)。ジョブは `scheduled_at` を持つふつうの配送なので、再試行・バックオフ・**同時に走る数の上限(`delivery` キューのワーカー数)**はいつもどおり。
- `DeliverySuspension` の配送は、お知らせがあっても保留されません(`Gate.exempt?/1`)。休んでいるピアにも、告げる側は後回しにされません。
- 取り消しは、先に署名した `held/<slug>.cancel.json` を公開の場所に置きかえ(`public/suspensions/<slug>.json`)、`Undo` を配ります。`Update` で運びたいときは `Publisher.update_activity/3`。

### 眠っている間の nginx

`public/control/…` と `public/suspensions/…` は、眠っている間、nginx が静的に返します(`sukhi-maintenance notice put DIR`、[`OPS_MAINTENANCE_PAGE.ja.md`](OPS_MAINTENANCE_PAGE.ja.md) §8)。

- `GET`/`HEAD`(人の窓ではないもの)には、用意した文書を **200** で返す。**`POST` は同じ URL でも `503` + `Retry-After`**(受け取る責任を持てないものに 2xx を返さない)。
- 休み中の `503` には `Link: <お知らせ>; rel="…#deliverySuspension"` を添える。相手の配送が、この `Link` から通知を探しに来る(段4の後半、`Hint`)。
- 取り消しは `notice cancel DIR`(先に署名した取り消しに置きかえ、`Link` を外す)。

**まだ**: 実機で通すこと(配る仕事・nginx とも、テストの相手では確かめた)。

## 記録するもの(`schema.edn`)

| 表 | 属性 | 中身 |
| --- | --- | --- |
| notices | `dsnotice/*` | お知らせごとに1行。`record` が JSON の全体(読み戻しの正本)。取り消しの行は「終わりの印」として残る |
| pending cancellations | `dspending/*` | 先に届いた Undo。`(actor, create_id)` で一意 |
| control evidence | `dsevidence/*` | 制御を最後に確認できた時刻・最後の試行・その結果(`Control` が書く) |
| controller cutoffs | `dscutoff/*` | 「この時刻より前は受けない」線 |

忘れるとき(`Store.sweep/2`)は、年齢上限を過ぎた notice と期限切れの預かりを消し、消した分だけ cutoff を進めます。方針をゆるめても、忘れた取り消しが蘇りません。`Upkeep` が1時間ごとに `sweep` を呼び、そのあと写しを組み直します。

## いまどこまで

| 段 | 中身 | 状態 |
| --- | --- | --- |
| 0 | 前提の補強(IPv6、DNS の固定、JSON の深さ) | merge 済み(#163) |
| 1 | 純粋な部品 `Origin` `Notice` `Policy` `Gate` | merge 済み(#165) |
| 2 | `Store`・`Receiver`・`Ingest` の分岐・proof の持ち主 | merge 済み(#167) |
| 3 | 配送への組み込み(保留・免除・再開・ETS) | merge 済み(#168) |
| 4 | 制御の確認(`Fetch` `Control` `Recheck`)・取り下げ | merge 済み(#184) |
| 4 の後半 | 配送の応答の Link ヘッダーから通知を取りにいく(ヒント) | merge 済み(#186) |
| 5 の前半 | 告げる側の芯(`Publisher`・`mix sukhi.suspension.prepare`) | merge 済み(#188) |
| 5 の中 | 眠っている間の制御の文書・配る仕事(`Announce`・`Spread`) | merge 済み(#190) |
| 5 の後半 | nginx で静的に返す道・休み中の 503 に `Link`(`sukhi-maintenance notice`) | この変更 |
| 6 | 管理画面と telemetry | 後 |

初版の範囲は段0〜3(段4で実際に休むようになりました)。宛先ごとの同時数、容量上限の記録、`Retry-After` は後回しです。
