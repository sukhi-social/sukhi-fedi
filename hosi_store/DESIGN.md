# sukhi 側の口(port)の設計 — 下書き

2026-11-17。nyanrus のレビュー前の下書き。sukhi-fedi には何も触っていない。
読んだのは: `notes/create.ex`、`notes/interactions.ex`(favourite)、`timelines.ex`(home の前半)、
`outbox.ex` の口、`backend.ex`、`graph/sweep.ex`、CODE_STYLE、FEDERATION_REDUCER の頭。
読んでいないのは: `social.ex`、`account_deletion.ex`、`ap/instructions/follows.ex`、timelines の後半。

## 0. 置き場の物差し(nyanrus, 2026-11-17)

**読み ＞ 書き ＞ 消し** になるデータが、hosigraph に置かれやすい。
ここでの「消し」は物理的な erase(clean と compact が付く)のこと。unlike / unfollow のような retract は、ふつうの 1 write で、数えない。
一括で消せるもの(Sweep)は、「消しが少ない」側に入れてよさそう(**この読みは nyanrus に確認中**)。

| 置き場 | 入るもの |
|---|---|
| hosigraph | 投稿、リモートの object、actor、follow、reaction、boost、timeline の元 |
| hosigraph の「窓」 | notification(受け取る人ごと)。khana は log を畳んだ捨てられる「now」なので、窓のように切るのは設計に合う。ただし**いまの hosigraph には窓が無い**(下) |
| PostgreSQL | Oban の queue、session、token、OAuth、下書き、予約投稿、既読位置、配送の `outbox` |

PostgreSQL は、すでに Oban で使っているものを、そのまま使う。新しい DB は足さない。

物差しから見えたこと: 前回の (Z)(§4)は、outbox 行を hosigraph に置く。
outbox 行は、書いて、1 回読んで、消える行で、物差しの逆側にある。
hosigraph 自身の event log を feeder が cursor で読む形にすれば、outbox 行そのものが要らなくなるかもしれない
(event log を読む `eventsAfter` / `eventsAfterEach` は Haskell の `Events` にあるが、**C ABI と hosigraph-ex には口が無い**(2026-11-17 に grep で確認)。足すなら口が要る。§4 はそれまで、いまのまま置く)。

**khana を読んで分かったこと(2026-11-17)**
- khana は「log を畳んだ now」で、捨てて作り直せる。`Events`(真実)は khana を知らない。設計メモにも「別の khana を上に載せやすい」とある。
- ただし、いまは **1 つの Hosi = 1 つの log + 1 つの khana**で、畳むときの絞り込みは無い(`foldGroup` は全 event を入れる)。
- `openHosi` ごとに khana の runtime(JVM backend なら常駐 JVM)が 1 つできる。ユーザーごとに Hosi を開くと JVM が増える。窓(同じ log を、述語で絞って畳む khana)なら、この重さを避けられるはず。窓は**まだ無い**。

## 1. 口の高さ

Repo(731 か所)の高さには、口を置かない。`Repo.get_by` や `Multi.insert` を写すと、
試作で捨てた「SQL の 1:1」に戻ってしまう。

置くのは、いまの Context が、すでに持っている「操作」の高さ。
`Notes.Create.create_status`、`Notes.Interactions.favourite`、`Timelines.home`、
`AccountDeletion`、`Graph.Sweep.run`。名前も引数も、呼ぶ側はそのまま。
その下に、実装を 2 つ並べる(いまの Ecto と、hosigraph)。

```
呼ぶ側(API/AP)  →  Context の操作(口)  →  Ecto 実装 / hosigraph 実装
```

口は「behaviour」にするのが素直。`Backend` の seam と同じ形(config で切り替え、shadow で比べる)に載せられる。
ただし `Backend` の seam は「純粋な計算」(DB もネットも無い)のためのもの。
口は DB を持つので、同じ道具をそのまま使うと言葉がずれる。**別の置き場(例: `Ports`)にして、切り替えの仕組みだけ借りる**のがよさそう。

## 2. 口の候補(試作で通ったものから)

| 口 | 試作 | いまの sukhi |
|---|---|---|
| `post(account, attrs)` → `{:ok, note}` / `{:error, …}` | `Notes.post` | `create_status` |
| `like / unlike` → `:ok` / `:already` / `:not_liked` | `Notes.like` | `favourite` / `unfavourite` |
| `boost` | `Notes.boost` | `reblog` |
| `follow / accept / unfollow` | `Follows` | `Social` |
| `timeline(:public \| :home \| {:author, a} \| {:tag, t} \| {:thread, n}, viewer, page)` | `Timeline` | `Timelines` |
| `ingest_object(remote)` | `Ingest.object` | `AP.Ingest.run` の書く部分 |
| `erase_account(account)` | `Accounts.erase` | `AccountDeletion` |
| `sweep(mode, opts)` | `Sweep.run` | `Graph.Sweep.run` |
| (口には出さない)hosigraph の outbox 行 → Postgres の `outbox` へ橋をかける feeder | `Outbox` の CAS cursor | `SukhiDelivery.Outbox.Relay` の手前に足す |

## 3. 口の形で、決めておきたいこと

**a. 返すものは Ecto の struct ではなく、ただの map(view)。**
いまは `{:ok, %Note{}}`(account と media を preload 済み)を返し、
`MastodonStatus.render` がそれを読む。hosigraph 側は struct を作れない。
→ render が読む欄だけを「NoteView」として決め、Ecto 側も view に直して返す。
どの欄を render が読んでいるかは、**まだ数えていない**(未確認)。

**b. 「失敗の語彙」を口で決める。**
試作は `:already` / `:not_liked` / `{:error, :duplicate}`。
いまの sukhi は `{:error, {:validation, errors}}` や `{:error, :not_found}`。
口に出る失敗は、いまの語彙のまま(呼ぶ側を変えないため)。hosigraph 側がそれに合わせる。

**c. 見える・見えないは、口の中で一回だけ。**
CODE_STYLE の「visibility はクエリの中」を守る。
`timeline(kind, viewer, page)` の viewer を受けて、実装が自分の中で絞る。呼ぶ側に「絞り条件」を持たせない。

**d. home の絞り込みは、まだ口に入れられない。**
いまの `home_query` は、フォロー・排他 list・list ごとの条件(media だけ、cw 隠し、boost 隠し…)・
block/mute・silence を、すべて見る。試作の home は「フォローしている人」だけ。
→ 口に載せる前に、「viewer の hidden / list の条件を先に集めて、値として渡す」形にできるかを見る必要がある。
(`Lists.home_filter_members` などの結果は、すでに「id の集まり」なので、渡せそう。**ただし後半を読んでいない**。)

## 4. 一番むずかしいところ: 「書く + 事件」を 1 つに(配送は Oban/Postgres のまま)

2026-11-17 午後、nyanrus の見直し: **配送は、いまの Oban(PostgreSQL)に任せる。**
いまの流れ(`Outbox.enqueue_multi` → Postgres の `outbox` 表 → `SukhiDelivery.Outbox.Relay` → Oban の job)は、
配送の側として、そのまま残す。再試行・失敗の記録・配送ノードの分け方も、触らない。

残る問いは 1 つ: **hosigraph に書いた note と、Postgres の `outbox` 行が、同じ transaction に入れない。**

- (X) hosigraph に書く → そのあと `Outbox.enqueue`。
  間で落ちると「書いたのに配送されない」。いまの保証(DB commit = event durable)が弱まる。
- (Y) 先に `outbox` を書く → そのあと hosigraph。
  間で落ちると「配送されたのに、note が無い」。もっと悪い。
- **(Z) hosigraph の中にも outbox 行を持つ(note と 1 write)。小さな feeder が、それを読んで Postgres の `outbox` 表に写す。**
  feeder の cursor は **Postgres の表**に置き、`outbox` への insert と cursor の更新を **同じ Ecto transaction**に。
  - 落ちたら transaction ごと戻る(hosigraph の読みは副作用が無い)。次の回で同じ所から。
    → Postgres への入りは、ちょうど 1 回。
  - 配送そのものは、リモートの都合で、もともと at-least-once(Oban の再試行)。ここは今と同じ。
  - 試作の cursor は hosigraph の entity を `:holds` の CAS で進めていた。これを Postgres の行に変えるだけ。
  - hosigraph の outbox 行は「配送の状態」を持たない。ただの追記(いつ・何を・誰が)。
    送った・失敗した、は Oban が知っている。二重に持たない。

勧めるのは (Z)。新しく足すのは feeder 1 つだけで、配送側は、まったく変えない。

(Z) の上で、まだ決まっていないこと:
- feeder は、どこで動かすか(gateway の supervisor の下で 1 つ。複数ノードなら、cursor の行を `FOR UPDATE` で取って 1 つだけ動かす)。
- `outbox` 行の側に、hosigraph の outbox id を持たせるか(unique にして、二重の保険にする)。表の列が 1 つ増える。
- 「配送したくない」操作(`local_only` など)は、いまは payload に載せているだけ。feeder は、hosigraph の行の payload を、そのまま写せばよい。
- 書いてから feeder が拾うまでの遅れ(いまは同じ transaction なので、ほぼ 0)。feeder の polling 間隔ぶん、配送が遅れる。
  → 数百 ms で足りるはずだが、**測っていない**。
- 後出しの変更: 投稿を消す(Delete)も event。erase で outbox 行そのものが消える設計(試作)とぶつかる。
  本人の削除は「Delete を配送する」→ 配送が済んだあとに掃除、の順が要る。→ 試作した(§10 の「投稿の削除とアカウントを閉じる job」)。

## 5. 切り替えと、くらべ方(strangler)

操作ごとに、config で実装を選ぶ。`Backend` と同じ形:

```elixir
config :sukhi_fedi, :ports, timeline: Ecto, like: Ecto
config :sukhi_fedi, :shadow_ports, timeline: Hosi
```

- **読みは shadow できる**: 主の答えを返しつつ、もうひとつにも聞いて、食いちがいを log に(引数は出さず、hash だけ。Backend と同じ)。
- **書きは shadow できない**(2 回書くことになる)。書きの移し方は 3 つ考えられる:
  - (i) 操作ごとに、一括で hosigraph に切り替える(その操作の過去データは先に移す)
  - (ii) 二重書き(Ecto が正、hosigraph はあとから追う)— 食いちがい時の正が曖昧で、勧めない
  - (iii) hosigraph が正、Ecto は「読み用の写し」に落とす — 移行の途中だけの形
  **決まり(2026-11-19、nyanrus): (i) で進める。移行作業は手動。**(ii)(iii) は取らない。

  手動の手順(案。like で試すのが最初。**まだ一度も回していない**):
  1. その操作の書きを、短く止める(アプリ側で 503 か、メンテ表示)。止めないと、写している間の書きが抜ける。
  2. 過去データを hosigraph に写す: `MigrateLikes.copy(db, pg)`(手で走らせる。何度走らせても同じ。先に投稿と人が hosigraph にあること)。
     通知も relay の行も作らない(履歴だから)。投稿か人が無い like は書かず、`missing` に出る。
  3. `MigrateLikes.verify(db, pg)` で、旧の件数・hosigraph にあった数・無かった組(理由つき)・hosigraph だけにある数(切り替え前は 0 のはず)を読む。数人ぶんの中身も目で見る。
  4. config を `like: Hosi` に変える。再開。
  5. 戻すとき: config を戻す。hosigraph にだけ書かれた分を Ecto に戻す手が要る(これも手動、同じ task の逆向き)。

## 6. 最初の一歩(軽くて、戻れる)

読みだけの shadow から。

- `timeline(:public)` と `timeline({:author, a})`。書きを動かさない。
- sukhi-fedi にはすでに graph store(Datalevin)がある。比べる相手は「いまの Ecto の答え」と「hosigraph の答え」。
- 先に、実データの投稿を hosigraph に流す道(Ingest の逆向き。import)が要る。
  hosigraph の `backfillSince` がそれに近い(別メモ)。**ここは未着手**。

そのあとに like / unlike(一番小さい書き。1 write、`:lacks` / `:holds` の CAS、counter 無し)。
この時、Notifications.create は commit の外(いまもそう)なので、そのまま。

## 7. 未確認(読んでいない・測っていない)

- render が読む欄(NoteView の欄)
- home の後半(list 条件)と、ほかの timeline の条件
- `social.ex` の follow(承認制・FEP の分岐)、`account_deletion.ex` の手順
- feeder の置き方(複数ノード時)と、polling の遅れ(§4)
- アカウント削除時、Delete の配送と、hosigraph の outbox 行の erase の順(§4)— 試作した(§10)。「配送済み」= `outbox.status = 'published'` が、follow の行を読む fan-out のあとかは、**配送側(delivery)のコードを読んでいない**
- id: sukhi は Snowflake の整数 id。hosigraph の id は別の式(時刻 << 21)。API の `max_id` / `since_id` を、
  どちらの id で言うか(FR-13)。**API に出る id が変わると、クライアントの cursor が壊れる**
- 1 万件より上の速さ(timeline は件数に比例して遅くなる)
- search(fulltext が無く、scan)
- session / token / Oban の queue は、Postgres に残す想定。これで合っているか

## 8. nyanrus に決めてほしいこと

1. 口の高さは「Context の操作」で、いい?(Repo の高さではなく)
2. 書きの移し方: **決まり — (i) 操作ごとに一括、手動で**(§5)。
3. §4 の (Z) でいい?(hosigraph にも outbox 行を持ち、feeder が Postgres の `outbox` へ。配送は今のまま Oban)
4. 最初の一歩は、public / author の読み shadow からで、いい?
5. API の id をどうするか(Snowflake を hosigraph の id の別名として持つ / 変える)。

## 9. hosigraph 側に足りないもの(試作で見つけたもの。issue にはまだしていない)

- **窓(window)**: 同じ log を、述語で絞って畳む khana。いまは 1 つの Hosi = 1 つの log + 1 つの khana で、`foldGroup` は全 event を入れる。
  `openHosi` ごとに runtime(JVM backend なら常駐 JVM)ができるので、ユーザーごとに Hosi を開く案は重い。
- **event log を読む口**: `Events.eventsAfter` / `eventsAfterEach` は Haskell にあるが、C ABI と hosigraph-ex には口が無い(cursor 以降の event を返す op が要る)。

- query の `:order-by` / `:limit`(今は全件を返して Elixir で切る)
- fulltext と tuple の schema
- dtlv backend で読みと書きが重なると open に失敗する

OSS に出す時は、nyanrus が読んでから。

## 10. 試作で確かめたこと(2026-11-17 午後: Postgres と窓を前提に)

置き場の物差し(§0)に沿って、2 つ足した。dtlv 27 passed(2 excluded)/ JVM 29 passed。

**Feeder(`feeder.ex`、Postgres は PGlite)** — 配送は今の Oban/`outbox` のまま、橋だけ。
- 1 round = 1 Postgres transaction: cursor の行を `FOR UPDATE` → hosigraph の outbox 行を読む → `outbox` に insert(sukhi の subject 名で)→ cursor を進める。
- round の途中で落ちても(`after_insert` で raise)Postgres には何も残らず、次の round が同じ行から。
- `source_id`(hosigraph の行 id)を unique にして、cursor を失っても二重に入らない。
- 変異で捕まる: cursor を進めない・source_id の guard を外す(各 2 本)。
- **捕まらない変異: `FOR UPDATE` を外す。** PGlite は 1 本の接続を多重にしているので、transaction が重ならない。同時の feeder の保証は、**本物の Postgres で確かめるまで未確認**。
- 窓の前提(event log を直接読む)は、この試作では**まだ使えない**(口が無いので)。source は hosigraph の outbox 行のまま。差し替える所は `Outbox.after_id` 1 つ。
- erase された行は配送されない(Delete の配送を先に済ませる順が要る。テストは「そうなる」ことだけ見ている)。

**Notification(`notifications.ex`)** — 受け取る人の窓、の代わりに、同じ DB の `notification/recipient`。
- 口は `ops` / `undo_ops` / `list` / `dismiss` / `clear` だけ。窓に移しても、呼ぶ側は変わらない。
- like と同じ 1 write で書く(sukhi は commit のあとに別で書いている)。自分の like と、リモートの作者には書かない。
- `key`(identity)で、同じ原因は 1 回。unlike で消え、もう一度 like すれば、また書かれる。
- アカウント erase で、持っていた分と、起こした分が消える。投稿を Sweep しても、その投稿の分は消える(`notification/note` を依存物に)。
- 変異で捕まる: unlike で消さない・erase が見ない・自分の like でも書く(各 1 本)。
- follow も済み(2026-11-17): 承認が要る follow は `follow_request`、要らなければ `follow`(sukhi の type 名のまま)。yes を言うと、同じ 1 write で request が follow に変わる。unfollow は、どちらの notification も消す。自分と、この server の account でない相手には書かない。変異 4 通り(accept が request を残す・unfollow が残す〔2 通り〕・誰にでも書く)が各 1 本で捕まる。dtlv 31 / JVM 33 passed。
- boost も済み(type は sukhi の `reblog`): boost と同じ 1 write で、作者に。二重の boost・自分の投稿には書かない。like と boost は別の notification。boost した人の erase で消える。変異 2 通りが捕まる。dtlv 34 / JVM 36 passed。spike には unboost が無いので、「boost を取り消すと消える」は未(like と同じ形で足せる)。
- mention も済み: `object/mentions`(ref・many)を足し、post と Ingest の同じ write で、ここの account にだけ(作者・リモート・重複は除く)`mention` を書く。key は `mention:<投稿の IRI>:<相手>`(IRI は書く前から分かる)。作者の erase で一緒に消える。Sweep の `:local_touch` に「ここの account を mention している」を足した(sukhi の規則と同じ)。変異 5 通りが捕まる。dtlv 39 / JVM 41 passed。
  - 気づき: mention された account を erase しても、他人の投稿の `object/mentions` の値(id の数字)は残る(in-reply-to と同じ扱い。「他人が書いたものは残る」)。物理的に消したいなら、liked-by のように先に外す道がある。決めていない。
- 既読位置も済み(`markers.ex`、Postgres): `markers(account_id, timeline, last_read_id text, version, updated_at)`、主キーは (account_id, timeline)。`upsert` は 1 文(`ON CONFLICT DO UPDATE SET version = version + 1`)で、sukhi の「読んでから書く」より取りこぼさない。`last_read_id` は文字列のまま中を見ないので、API の id をどうするか(§7)に縛られない。`get` は home / notifications だけ。`Notifications.count_after` で「位置より新しい通知」=未読が数えられる。変異 5 通りが捕まる。dtlv 42 / JVM 44 passed。
  - **account の erase は 2 つの store をまたぐ**: `Erase.account(db, pg, account)` が、hosigraph(`Accounts.erase`)→ Postgres(`Markers.erase` と、feeder が写し済みの outbox の行=payload の `account_id` が本人のもの)の順に呼ぶ。順は固定: hosigraph が先に手放せば、feeder はもう写すものが無い。2 つにまたがる transaction は無く、各段が「いまあるもの」を見るので、途中で止まっても呼び直せば済む(test 3 本・変異 4 通りが捕まる)。残る隙: hosigraph の erase の最中に回っていた feeder の round があとから commit した行は、次の呼び出しで消える(それまでは id だけで本文は無い)。**誰が呼ぶかは決まり(2026-11-19、nyanrus): job**。sukhi の閉じる手順はもともと Oban の cron worker(`AccountDeletion.Worker`)で、request は 24 時間後の予約を入れるだけ。呼ぶのは、その job の最後の 1 段(下)。
  - **PGlite は 1 本の接続を多重にして、メッセージが混ざる**(`unnamed prepared statement does not exist`)。同時に 2 本の接続が要る test(feeder の 2 本・markers の同時 upsert・`FOR UPDATE`)は `:concurrent_pg` にして、本物の Postgres(`HOSI_PG_PORT=5432 mix test`)のときだけ走らせる。本物の Postgres(Postgres.app、5432、`HOSI_PG_DB=hosi_spike`)で走らせて通る。
- boost の取り消しも済み(`Notes.unboost`): boost の entity と、その通知(`reblog`)を 1 write で外し、relay には `UndoAnnounce` の行を書く(feeder が `sns.outbox.announce.undone` に写す。sukhi の subject 名は sukhi-fedi に在るのを確かめた)。無ければ `:not_boosted`、取り消してから boost し直すと新しい boost になって、また通知する。変異 3 通りが捕まる。同時に 2 か所から取り消しても 1 回で、relay の行も 1 つ、にする `:holds` の守りは、JVM khana でしか走らせられない test(`:concurrent_read`)にしてあり、**この環境は JVM が見えないので、その test はまだ走らせていない**。
- 本文からの @ も済み(`Mentions.extract(db, text)`、口の外): 人が書いた素の文章(html になる前)から、`@name`(ここの人)と `@name@host`(その host の人。host がここなら、ここの人)の actor id を、最初に出た順に 1 回ずつ返す。`Notes.post` の `mentions:` にそのまま渡せる。知らない人は外す(リモートの人は、投稿が届いたときに知る)。`me@x.org`・`/@bob`・`@@bob` は mention でない。大小は、書かれたまま→小文字の順に探す。変異 5 通りが捕まる。
- 既読を付ける操作も済み(`Markers.advance`・`read_notifications`): 位置は前にしか進まない(数字の id は数として比べる。「1000」は「999」より後)。SQL 1 文で、遅れている端末が既読を戻さない。数字でない id は、比べられないのでそのまま置く。`read_notifications` は一番新しい通知の id まで進める(通知が無ければ `:nothing`)。変異 3 通りが捕まる(1 つは test を足して捕まえた)。
- **投稿の削除とアカウントを閉じる job**(2026-11-19):
  - `Notes.delete(db, note, actor)`: 投稿・それへの boost・それへの通知を 1 write で外し、relay に `Delete` の行を書く。行は**投稿の IRI を持つ**(`outbox/ap-id`。投稿はもう無いので、あとから引けない)。他人の投稿は `:forbidden`、無ければ `:not_found`(2 回目も)。pin されていれば外す(Remove は書かない。Delete が言っている)。他人の返信は残る。これは erase ではない(log に事実は残る)。
  - `Notes.pin` / `unpin` / `pinned`: `actor/pinned`(ref・many)。relay には `Add` / `Remove`(feeder が `sns.outbox.add.created` / `remove.created` に写す。payload は sukhi の `note_ap_id` の形)。自分の投稿だけ。2 回は 1 回。**「Remove の配信」は、これのこと**と受け取った(sukhi の `sns.outbox.remove.created` は featured からの取り外し)。違っていたら教えてほしい。
  - feeder の payload: `Delete` は `{note_id, ap_id, account_id}`(sukhi の `enqueue_note_delete` と同じ鍵)、`DeleteActor` は `{account_id, ap_id}`(sukhi は `{account_id, username}`。**username は載せていない**ので、delivery が読むなら足りない)、`Add` / `Remove` は `{note_id, note_ap_id, account_id}`(sukhi の `pinned_id` は無い)。
  - `AccountClosing.step(db, pg, account)`(job の 1 歩): ①投稿を 50 件ずつ、`Notes.delete_ops` で作った ops を 1 回の `Hosi.write_many` で書く(§11) ②アカウントに `DeleteActor` を 1 回だけ ③そのアカウントの行がすべて Postgres に写され `published` になるまで `:waiting` ④ `Erase.account` して終わりの印。順は固定で、**配り終える前に erase しない**(`Erase.account` は outbox の行も消すので、未配送の Delete が消える)。印(`actor_deleted_at` / `finished_at`)は Postgres の `account_closings`(sukhi の `account_deletions` の行に当たる)。途中で止まっても呼び直せば済む(test 13 本・変異 17 通りのうち 16 が最初から捕まり、1 つは順を見る 1 行を足して捕まえた)。
  - 変えたこと: schema に `actor/pinned` と `outbox/ap-id`(既存の store は schema の取り込みが要る)。`Sweep` の edge に `actor/pinned`(pin は自分の投稿にしか付かず、sweep はよそから来たものしか取らない)。
  - 同時に 2 か所から消す / 取り消すときの `when` の守りは、JVM でしか走らせられない(**この環境は JVM が見えず、未実行**)。
- 未: リモート作者の判定のテスト(like 側)。sukhi は (受け取る人, 起こした人, type, note) で冪等。ここでは `key` がそれに当たる。

**見つかったこと**
- like が先に作者を読む(書く前の read)ので、dtlv では「同時に 20 人が like」のテストが落ちた(読みと書きの重なり。既知の dtlv の癖)。
  そのテストは `:concurrent_read`(JVM のみ)に移した。sukhi の `favourite` は note を先に読んでいるので、呼び出し側が author を渡せるなら、この read は要らない。
- PGlite は、test ごとに pool を作ると、閉じた socket を残して次が落ちる。run 全体で 1 つの pool にした。

## 11. 操作の重さ(2026-11-19: hosigraph #25 の main で数えた)

**物差し**(hosigraph #25 の本文の数字。書いた人の環境で、日ごとに 2 倍ほど動く。ここでは測り直していない。JVM khana):
write 1 回 約 8 ms(まとめて書けば 1 件 約 0.5 ms)・id で 1 件読む 約 0.3 ms・新しい 20 件の query 約 3.5 ms・id の lookup 約 0.65 ms。
つまり**重いのは write の往復の数**で、読みの往復はその 1/20〜1/3。この環境の dtlv(1 往復ごとに process)では、1 往復はどれも約 23 ms で、重さの比は出ない。**往復の数だけを、portable な物差しにした**。

**操作ごとの往復**(`Hosi.request` を trace して数えた。write / query / get_entities):

| 操作 | w | q | g |
|---|---|---|---|
| post(mention 2 人・返信は get が 1〜2 増える) | 1 | 0 | 0〜2 |
| like / pin / unpin / follow | 1 | 0 | 1〜2 |
| unlike | 1 | 1 | 1 |
| boost | 1 | 0 | 4 |
| unboost | 1 | 2 | 4 |
| accept / unfollow | 1 | 2〜3 | 2 |
| notifications.list | 0 | 1 | 1 |
| timeline.public / thread | 0 | 1 | 2〜3 |
| timeline.tagged / search | 0 | **6** | 0〜2 |
| timeline.author | 0(highest_in 1) | 0 | 3 |
| timeline.home(2 人フォロー) | 0(highest_in 2) | 2 | 4 |
| Notes.delete(boost 5・通知 10) | 1 | 2 | 3 |
| Notifications.clear(通知 10) | 1 | 1 | 1 |
| AccountClosing.step(投稿 10) | 1(write_many) | 21 | 30 |

- 書く操作は、どれも write 1 回。往復の下限にいる。
- `tagged` / `search` / `public` / `thread` の query 数は、空いた窓を 6h → 24h → … と広げる分(`Timeline.windowed`)。`:limit` は query を安くしない(全部 sort してから切る)ので、窓で絞ってから切るのは作法どおり。窓が足りないほど疎なときだけ増える。tag は多値で tuple にできず、search は走査なので、窓のまま。
- `author` と `home` は、schema の tuple 属性 `object/by+at`(書いた人, 投稿時刻)と `activity/by+at`(boost した人, 時刻)を `Hosi.highest_in` で歩く(窓を広げない)。tuple 属性は store が作る(書かない)ので、`Store.retract_ops` は外す。
  - **`author` の並びは、投稿時刻(`object/published`)の新しい順になった**(前は id 順)。cursor は今までどおり id(`before:`)で、その投稿の時刻と id の次から読む。ローカルの投稿では同じ並び。遅れて取り込んだ古い投稿は、前は先頭に出たが、いまは時刻の位置に出る。
  - `highest_in` は filter を取れない。見える投稿が足りない page は、次を倍の大きさで読む。
  - `home` は、投稿の source と boost の source を、1 page より 1 件多く読み、**最後に読んだものより新しいものだけ**を確かとする(外れたものは、それ以上新しくないため)。足りなければ倍で読み直す。
  - 「フォローしている人の投稿は自分の時刻で出る」の判定を、**書いた人がフォロー先か**で決めるようにした。前は「いま読んでいる範囲に入っているか」で決めていて、自分の時刻が次の page に入る投稿が、boost の時刻でもう一度出ていた(前からの不具合。test を足した)。
- `Notes.delete` / `clear` は、外すものを `Store.retract_ops_many` で 1 回の get にまとめて読む(boost や通知の数に依らない)。
- `AccountClosing.step` は、投稿の batch を 1 回の `write_many`(1 回の fsync で、投稿ごとに原子的)で書く。`write_many` に `when` は付けられないので、同時に別の道(自動お掃除の job・board の撤去・job の重なり)が同じ投稿を消すと、同じ delete がもう一度書かれる。試すと、**エラーにならず、事実は変わらず、log にイベントだけ増える**(2 回目の write も write_many も ok)。`Delete` の outbox の行は 2 本になるが、**同じ Delete が 2 回配られることは、ActivityPub の冪等性(受け取る側は、無い投稿への Delete を無視する)に任せる**と決めた(2026-11-19、nyanrus)。sukhi の配信も `(activity_id, inbox_url)` の unique で、送った印のあとの 2 回目は止める。断られた batch は raise する(**この spike の ops では断られる batch を作れず、この raise は test されていない**)。
- `WriteQueue`(同時の書き手をまとめる)は hosigraph 側にある。hosigraph-ex(NIF)の口には、まだ出ていない。

**時間**(この環境の dtlv は 1 往復ごとに process で、1 往復が約 23 ms。**往復の数がそのまま時間になる**。JVM の時間は次の段落): `author` 約 205 → 約 100 ms、`home`(2 人フォロー)約 450 → 約 200 ms。

**JVM で測った時間**(2026-11-19、JDK 21・常駐 JVM の khana・15 回の中央値。60 人をフォロー・2200 投稿・boost 150。#25 の物差しの数字は測り直していない):

| 操作 | 前 | 今 |
|---|---|---|
| author(200 投稿の人) | 6.5 ms | 2.3 ms |
| author(15 投稿の人) | 14.2 ms | 1.8 ms |
| home 1 ページ目 | 124 ms | 8.0 ms |
| home 2 ページ目 | 4.8 ms | 7.6 ms |
| アカウントを閉じる: 投稿 50 件を消す | 141 ms | 87 ms |
| 通知 15 件の retract の読み | 2.8 ms | 0.44 ms |

- home の 1 ページ目は、前と今で同じ id が返る(確かめた)。2 ページ目は今のほうがわずかに遅い。前は窓が小さくて当たりが早かったためと思う(原因までは見ていない)。
- 投稿 1 件の write は約 0.5 ms。閉じる 87 ms は、write でなく 1 件ごとの `delete_ops` の読み(往復)が大きいと思う(切り分けは未)。読みを束ねれば縮められるかもしれない。
- 手元の合成データ 1 通り。実データの形(boost の多さ、フォロー数)では変わる。

**見つかった不具合**: follow の通知の key が `"follow::<from>"` で、宛先が入っていなかった。同じ人が 2 人目をフォローすると、通知が unique 違反になり、write 全体が断られて `:already` と返った。key の note の場所に、フォローされた人を入れた(`undo_ops` も、followee を渡す)。test 1 本(2 人をフォロー)を足した。

**決まったこと(2026-11-19 nyanrus)**: author の並びは投稿時刻(`object/published`)順でいい。ページ送りの目印は今は id のまま(`place_of` で引き直す)。限界が見えたら、そのとき考え直す。

## 12. sukhi の Postgres から写す(2026-11-19)

like だけを切り替えようとして見つかったこと: sukhi では like は `reactions` の行(account_id・note_id・emoji ⭐)で、
投稿(`notes`)も人(`accounts`)も Postgres にある。spike の like は、投稿と人が hosigraph にあることが前提なので、
切り替えの前に、その 2 つを写す道が要る。`ImportPg`(手でやる・やり直せる)がそれ:

- `actors/3` → `notes/3` → `verify/3` の順。人の IRI は、ここの人は `https://<domain>/users/<username>`、
  リモートは `actor_uri`(sukhi の `Graph.Project.actor_iri` と同じ規則)。投稿の IRI は `ap_id`。
- 運ぶもの: 人(IRI・username・host・local?)、投稿(IRI・作者・published〔µs〕・local?・visibility・
  表示する HTML〔`content_html`、無ければ `content`: `Note.html/1` と同じ〕・返信先と root)。
- 運ばないもの: tags・mentions・media・poll・CW・boost・follow・pin・通知。それぞれ別の段。
- 親が `notes` に無い返信は、そこが thread の頭になり、`in-reply-to` は付けない。visibility が知らない値なら
  いちばん狭い `:direct`(広く見せる側には倒さない)。
- 投稿の索引(id・IRI・親の IRI)は走る間メモリに持つ。数百万件の規模は想定していない。
- 試した所: 親のほうが大きい id の thread(深さの順に書く。壊すと test が落ちる)・やり直し・作者が無い投稿と
  `ap_id` が無い投稿(`missing` に名前が出る。人を写してもう一度走らせれば直る)。
- like の元の行も済み: `MigrateLikes.copy/3`・`verify/3` に `domain:` を渡すと、sukhi の `reactions`(emoji が ⭐ のもの。
  `Notes.Interactions.favourite_emoji/0`)を `notes`・`accounts` と結んで読む。view は作らず、問い合わせの中で
  IRI を作る(ここの人は domain から、リモートは `actor_uri`。domain は設定で変わるので view に焼かない)。`domain:` 無しは
  従来の `old_likes` 表のまま。⭐以外の reaction(Misskey 風)は運ばない。`ap_id` の無い投稿への like は元の行に
  現れない(その投稿は `ImportPg.notes` が `:no_ap_id` で名前を出す)。`actor_uri` の無いリモートの人の like は
  `missing` に `{note_iri, nil}` で出る。
- まだ: 新しく作られる人と投稿を両方に書く道(sukhi 側の Multi に足す)、like の切り替え(config)、本物の sukhi の DB での試走。

## 13. 両書き: sukhi の store を追いかける(2026-11-20)

「新しく作られる人と投稿を両方に書く」は、書く道(Multi)に手を入れず、**追いかける**形にした。`Graph.Local` が
outbox を追うのと同じ考え方: sukhi の store の書き方は変えず、前回の id より後ろを読んで hosigraph に写す。
どの道で作られた投稿(local の API・inbox・deco・backfill)も、id で一度は通るので、道ごとに hook を足さずに済む。

- `Copy`: 人と投稿と like を hosigraph に書く、ただ一つの場所(`ImportPg`・`MigrateLikes`・`Tail` が呼ぶ)。IRI で探すので、あるものは触らない。
- `Source`: 元の読み口の約束(`{module, arg}`)。sukhi の `Repo` は PostgreSQL にも Datalevin にも向く(`SUKHI_STORE`)ので、
  生の SQL ではなく、sukhi-fedi 側が `Repo` 越しに読む module を渡す。`Source.Postgres` は裸の Postgres 用(test と手でやる時)。
- `Tail.sync/3`: 1 回分。人 → 投稿 → like → sweep の順。cursor は hosigraph の中(`relay/name` = `tail:accounts` / `tail:notes` / `tail:likes` / `tail:sweep`)。
  cursor は、それより前を書き終えてから動かす。書くのは IRI で冪等なので、途中で止まっても次で直る。
- 投稿が cursor に追い越されないための 3 つ: (1) 作者: 無ければ source に聞いて先に写す。source にも無い作者(消えた人の
  投稿)だけ `:no_author` と名前を出して諦める。(2) IRI: local の投稿は `ap_id` 無しで入って直後に付く。無くて 60 秒未満なら、
  そこで止まって次の回に待つ。それより古ければ `:no_ap_id` と名前を出して諦める。(3) 返信が親より先: 同じ回に居れば親が先。
  親が後の回なら、返信は thread の頭のまま(書き直さない)。
- like(⭐だけ。`Copy.favourite/0`)は、投稿のあとに追いかける。投稿が hosigraph にまだ無ければ、その like の手前で止まって次の回を
  待つ(投稿を書くのは notes の段だけ。like の側で「無ければ写す」をすると、順番(返信の親が先)を崩す)。60 秒たっても投稿が
  無い、または source にも無い like は、`likes_missing` に `{like_id, :no_note | :no_ap_id}` で名前を出して諦める。reactor に IRI が
  無ければ `:no_iri`。
- **sweep(消えたものを外す)**: 消された行には、id より後ろを読む cursor からは何も見えない。そこで逆から見る: hosigraph が
  持っている投稿を `object/published` の新しい順に `batch` 件(窓。`Hosi.highest`)取り、source に「この IRI のうち、まだ在るのは」
  (`notes_by_ap_ids`)と「この投稿の ⭐ は誰から」(`likes_of_notes`)を聞く。返ってこない投稿は `Notes.forget_many_ops`
  (`Notes.delete` と同じ retract。配るための outbox の行は書かない: 配るのは store 側の削除がもう済ませている)。store に
  無い ⭐ は `object/liked-by` から外す。窓は `tail:sweep` が覚える(最後に残った投稿の id)。`batch` より短い窓は一周の終わりで、
  cursor を 0(いちばん新しい所)に戻す。
  - hosigraph を先に読み、store をあとで読む。間に作られた like を「取り消された」と見ないため。
  - source が答えられない時は例外にする(空を返さない)。空は「全部消えた」と読まれて、全部外してしまう。
  - 外したものは log には残る(retract。Erase は別の重い操作)。
  - 間隔: Server は 10 秒に 1 回(`sweep_every`)と、`sync_now` の時に回す。2 秒の tick ごとには回さない(store に窓ごと 2 回聞くので)。
    1 回で窓 1 つ(`batch` 既定 200)なので、N 件の投稿が一周するのは N/200 回 × 10 秒。例えば 1 万件で約 8 分。**計算で、測っていない**。
- **store が真実**: sweep は、store に無いものを hosigraph から外す。ある種類の書き込みを hosigraph に移すとき(like を hosigraph に
  直接書く、投稿を hosigraph に直接書く)、hosigraph にしか無いそれが「消えた」に見える。移す前にその種類の追いかけ(と sweep の
  該当部分)を止める。store を丸ごと空にする(DB を作り直す)と、hosigraph の投稿も窓ごとに全部外れていく。
- **追いかけないもの**: 編集、follow、boost、⭐ 以外の reaction。hosigraph を読む側がまだ無いので、古いものを読む人は居ない。
- like を切り替えたあと(like の書き込みが hosigraph に直接行くようになったあと)は、様子が変わる。作られた直後の投稿に like が
  来ても、追いかけが次の回を待つ間は hosigraph に投稿が無い。直接書く側が、無ければ `Copy` で写してから書く(来た場所で写す)。
  そのときは like の追いかけと sweep の like の部分を止める(hosigraph にだけある like を、追いかけが「無い」と見なさないために)。
