<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Datalevin のデータ構造(ひなたさんのドラフトの見直し)

ドラフトを土台に、dtlv 1.2.10 で実際に読み込んで動かし、穴と直し方をまとめた。
改訂版のスキーマは [`elixir/priv/datalevin/schema.edn`](../elixir/priv/datalevin/schema.edn)(168 属性、そのまま読み込める。正本はこの 1 つ)。
まだ実装には接続していない。今の `SUKHI_STORE=datalevin` は Postgres のカタログを 1 対 1 で写した構造で動いている([DATALEVIN.md](DATALEVIN.md))。

## 前提(変えていない)

- 配送キューは SQLite。ここには持たない。
- remote actor は掃除で消さない。
- `:object/raw` は必須(FEP-8b32 の証明検証と転送)。
- 削除は Tombstone(`:object/deleted-at`)。
- contentMap は必要なときだけ `:content/*` に展開する。
- ホームの重複まとめは後回し(でも属性は先に決めた。下の「entry」)。

## 実際に確かめたこと

| 項目 | 結果 |
| --- | --- |
| ドラフトの読み込み | 通る(106 属性) |
| ref・instant・keyword を含む tuple | 通る。部品が nil の行も `[x nil]` で索引に入る |
| 複合 identity(`:follow/pair` など)の upsert | 通る。同じ組を 2 回入れても 1 件 |
| 著者ごとの時系列(`index-range`) | 通る。10 万件・500 著者で 1 人 200 件を引ける(プロセス起動込みで 1 秒未満) |
| 10 万 object の大きさ | 82 MB(`raw` は短い文字列。実データはその分増える) |
| 再帰ルール `ancestor` | 3 段のスレッドで通る |
| nil の値 | **書けない**(`Cannot store nil`)。属性ごと省く |

## ドラフトの穴と直したところ

1. **全文検索が動かない。** `:db/fulltext true` だけだと `(fulltext $ :object/content "q")` が
   `:db.fulltext/autoDomain is not true` で落ちる。`:db.fulltext/autoDomain true` を足した。
2. **日本語が当たらない。** 既定の分かち書きは日本語を切らず、「猫」で「日本語の猫」が見つからない。
   dtlv の `exec` からは analyzer を差し替えられなかった(組み込み側なら可能かもしれない)。
   分かち書きは Elixir 側で行い、結果を `tokens` 属性に入れる(下の「決定済み」)。
3. **tuple の範囲検索は eid で。** 境界に lookup ref(`[:actor/id "…"]`)を渡すと ClassCastException。
   先に actor の eid を引いてから `[aid t0]`〜`[aid t1]` を渡す。クエリ層で 1 か所にまとめる。
4. **`to` / `cc` の行き先が定義されていなかった。** `as:Public` や followers は actor ではないので ref の先がない。
   `:collection/id`(identity)の entity にして、`to` / `cc` は actor と collection の両方を指せるようにした。
   ref は先の種類を問わないので追加の仕掛けは要らない。
5. **ホームの `entry` が未定義だった。** `:entry/owner` `:entry/object` `:entry/via`(多値)`:entry/at` と、
   `(owner, object)` の identity を定義した。同じ投稿がブーストで再び来ても upsert で 1 件に畳まれ、
   via に人が増えるだけ(確認済み)。これでドラフトの TODO の「畳む」は構造としては解ける。
   書き込み時に配るか、読むときに followee の `author+published` を merge するかは未決。既定は後者(空のまま)。
6. **identity が 2 つある actor。** `:actor/id` と `:actor/did` の両方が identity だと、別々に作られた 2 件を後から同一視できず upsert が衝突する。
   取り込み側で先に統合する約束にした(コメントに明記)。
7. **API 用の安定 ID がない。** eid は再構築で変わる。ページ送りと Mastodon API の ID 用に
   `:actor/sid` / `:object/sid`(long、identity、アプリで採番)を足した。Postgres の `id` はここへ移す。
8. **重複防止が足りない。** block / mute / bookmark / pin / tagging / vote を `*/uniq` の複合 identity にした。
   一方 `activity/actor+type+object` は identity にしない(Create は object が毎回違い、Undo で消える種類もある)。
9. **索引が足りない。** ローカルタイムライン用の `local+published`、スレッド用の `root+published`、
   ブースト数・いいね数用の `activity/object+type`、リアクション集計用の `reaction/object+key` を足した。
10. **Postgres に有って、ドラフトに無かったもの。** `handle`(`user@host`、ローカルは host 無し。nil の host でも upsert できた)、
    引用、タイトル、MFM、絵文字の参照、ポール、ブックマーク、ピン、リスト、通知の既読・非表示、添付の寸法。

## Postgres との対応

| Postgres | Datalevin | 備考 |
| --- | --- | --- |
| `accounts`(ローカルと remote) | `:actor/*` + ローカルは `:user/*` | 鍵は `:key/*` に分ける(複数鍵・失効のため) |
| `notes` | `:object/*` | `conversation_ap_id` → `:object/root`、`in_reply_to_ap_id` → ref |
| `note_tags` / `tags` | `:tagging/*` | タグ名は小文字化 |
| `note_media` / `media` | `:attachment/*` | アップロード管理は B 層 |
| `boosts` | `:activity/*`(type = `:Announce`) | 数は `activity/object+type` |
| `reactions` / `custom_emojis` | `:reaction/*` / `:emoji/*` | |
| `follows` / `follow_requests` | `:follow/*` | `state` で pending / accepted |
| `notifications` | `:notification/*` | |
| `blocks` / `mutes` | `:block/*` / `:mute/*` | |
| `bookmarks` / `pinned_notes` / `lists` / `list_accounts` | `:bookmark/*` / `:pin/*` / `:list/*` | |
| `polls` / `poll_options` / `poll_votes` | `:poll/*` / `:choice/*` / `:vote/*` | |
| `instance_blocks` | `:instance/*` | severity → `state` |
| `outbox` / `oban_*` / `delivery_receipts` / `outbound_events` | SQLite | 配送キュー |
| 残り(`oauth_*` `sessions` `webauthn_*` `push_subscriptions` `invite_*` `admin_audits` `reports` `announcements` `deco*` `pull_*` `markers` `maintenance_runs` `metric_samples` など) | B 層 | グラフの形ではないので、カタログから機械的に写す(今の実装のまま) |

A 層(グラフの芯)だけ作り直し、B 層は今の 1 対 1 のまま残す、という切り分けを提案する。
B 層まで手で設計し直す価値は小さく、変えるほどバグの面積が増える。

## 実装の状況

出来ている(単体テストと、実際の `dtlv` を使う通しテスト済み。どれも既存のアプリには未接続):

- `SukhiFedi.Graph`(+ `Supervisor`): グラフ用の別 DB(`<DATALEVIN_DIR>/graph`)と専用の `dtlv` 子プロセス。
- `Graph.Ingest.object/2`: 1 件の取り込み(IRI で upsert)。author・宛先・メンションを stub で作り、`to`/`cc` を actor / collection に結び、
  `visibility` を `Audience` で導き、`root`(順序が逆に届いても、後から親が来た時点で付け替える)、`sid`(Snowflake、再取り込みで不変)、
  `raw`(`RawStore` 経由)、`content-html` と `content-mfm`、contentMap の展開、ハッシュタグを 1 トランザクションで書く。
  `tombstone/2` は本文・原本・言語別の本文を消して `deleted-at` を付ける。
- `Graph.Tokens`: 分かち書きのバッチ。`tokens` の無いものを `limit` 件ずつ処理し、サービスが落ちていれば最初の失敗で止まる。
  `reset/0` で作り直せる。リアルタイムの分かち書きは(MAY として)持たない。検索側は `query_text/3` で同じ分かち書きをかける。
- `Graph.Sweep`: 掃除。候補は索引(`received-at`)で取り、保持ルール(`local_thread` `young_thread` `local_touch` `followed`)を batch に 1 回だけ当て、
  残りと子(`content` `attachment` `tagging` `reaction` `poll`→`choice`→`vote` など)を 1 トランザクションで消す。`:dry_run` は理由ごとの内訳を返す。
  `gc/1` は blob を 1 つずつグラフに問い合わせて、参照のないものだけ消す(参照の全列挙はしない)。
  スキーマの ref 属性がすべて「子」か「辺」に分類されていることをテストで見ている(新しい ref を足すと落ちて、扱いを決めさせる)。
- `RawStore` / `Tokenizer` / `SchemaFile`: 前の段のとおり。

実測で分かって直したこと:

- **時刻は instant ではなく long(µs)にした。** `dtlv mcp` の JSON では instant を書けない(`Expect java.util.Date`)。
  既存のストア(`Datalevin.Types`)と同じ約束で、範囲比較もそのまま通る。
- キーワード値、lookup ref、`ground` によるコレクション束縛、`:order-by`/`:limit`、`not`/`not-join`、`retractEntity` は JSON 経由で通る。
- 同じミリ秒に複数の object が来ても、`sid` はそのミリ秒の最大値+1 を取るので重ならない(65,536 件を超えたら明示的に失敗する)。
- 取り込みの速さ: `strict`(WAL を毎回 fsync)で 1 件あたり約 6ms(500 件)。バックフィルは束ねて書く余地がある(未実装)。

接続と運用(`SUKHI_GRAPH=1` のとき):

- 受信の入口 `AP.Ingest` の、実行が済んだ後に `Graph.Mirror.admit/2` が 1 件ずつ(受け付けた順に 1 プロセスで)グラフへ写す。
  埋め込み object が actor と別のホストなら(作者が署名していない限り)写さない。失敗しても受信の応答は変わらない。
- cron: `Tokens`(5 分ごと)、`Sweep`(毎日。既定は dry-run で、`SUKHI_GRAPH_SWEEP=execute` で初めて削除)。変数は `docs/ENV.md`。
- ベンチ: `mix sukhi.graph.bench`(合成データを実際の取り込み経路で入れ、読み取りを書き込み直後の冷えた状態で測る)と、
  `.github/workflows/graph-bench.yml`(PR の数字を main と並べて要約に出す。報告のみで、落とさない)。
- 読み取りは 2 段(並べ替え用の最小クエリ → `pull_many`)で、窓(`sid` の範囲)を広げながら探す。範囲検索の道具が `dtlv mcp` に無いため。
  速さの残りは TODO.md。

受信以外の取り込み(`SUKHI_GRAPH=1` のとき。`Graph.Project` と `Graph.Local`):

- 入口は 1 つのまま。ローカル行を ActivityPub の JSON で言い直し(`Project`、純粋関数)、`Graph.Activity.record/2` に渡す。
  ノートを書く別経路は作らない。活動の id は行の id から決めるので、同じ行を 2 回書いても 1 件になる。
- **outbox を追う**(`Local`)。連合する操作はすでに同じトランザクションで `outbox` に行を書いている。それを id 順に読んで写す
  (ノート作成・更新・削除、Like / リアクション / ブーストとその取り消し、フォロー依頼と取り消し、ピン、プロフィール更新)。
  カーソルはグラフの中(`sync/outbox`)。最初の起動は最新の行から始める(それ以前は既存データの取り込みの仕事)。
  一時的な失敗は 5 回まで再試行して先へ進まず、消えた行のような永続的な失敗は飛ばす。
- **フック**。連合しないもの(ブックマーク、リスト、ローカル投票、ローカル同士のフォロー)は `Local.changed/1` を投げ、
  行を読み直して「グラフを行に合わせる」。落ちても二重でも、次に呼ばれたときに正しくなる。
- 添付・投票(`Question` の選択肢と票)・カスタム絵文字は、受信側(`Ingest` / `Activity`)も同じ形で取り込む。
- 通知: ローカルのノートが名指した人(本文の `@name`、`Notes.Create.local_mentioned_ids/1` と同じ規則)は `Mention` タグにして渡すので、
  受信と同じ経路で `mention` / `reply` / `favourite` / `reblog` / `follow` の通知ができる(宛先がローカルのときだけ、自分には作らない)。
- 既知の穴: `dm.created` は無視する(ノート作成で足りるため)。編集で外した添付は消えない。

API の読み取り(`SUKHI_GRAPH_READ=1`。`Graph.Timelines`):

- 公開(ローカル)・ハッシュタグ・リストのタイムラインは、**どの投稿をどの順で出すか**をグラフが決め、投稿そのもの(件数・メディア・閲覧者ごとの状態)は
  これまでどおり関係 DB から読む。Mastodon JSON を作るコードは 1 つのまま。`max_id` は note id → `ap_id` → `sid` と読み替える。
- グラフが厳密に答えられないときは関係 DB のクエリに戻る: ページが足りない(既存データがまだ入っていないだけかもしれない)、
  `since_id`/`min_id`、`only_media`/`hide_sensitive`、カーソルの投稿がグラフに無い、グラフの失敗。タイムラインは、グラフを入れる前より空にならない。
- **Postgres 無しで動かす**には `SUKHI_STORE=datalevin`(関係 DB 側が Datalevin になる)に `SUKHI_GRAPH=1` `SUKHI_GRAPH_READ=1` を足す。
  ホーム・通知・スレッドは、その関係 DB 側(= Datalevin)から今までの意味のまま読む。グラフ経由の統合テストは両方の構成で通る。
- ホーム・通知・スレッドをグラフが選ぶ形はまだ。ホームはミュート・ブロック・リストのゲート・ブースト・キーワードなど規則が多く、同じ意味に移すのに別の一段が要る(TODO.md)。

まだ(この先):

- 既存データの取り込み(Postgres → グラフ)、ホーム・リスト・通知・スレッドの読み取りの切り替え。
- 読み取りの速さ、韓国語の分かち書き(TODO.md)。

## 移行の道筋

1. A 層の表を `schema.edn` の形で受ける「第二のストア層」を、今の Ecto アダプタ越しではなく Datalog で直接書く(読み取りから)。
2. 読み取り側(タイムライン・スレッド・通知)を Datalog クエリに替え、書き込みは今のアダプタ(Postgres 形)と二重書きして突き合わせる。
3. 一致を見てから書き込みを切り替え、Ecto 形のテーブルを A 層から外す。
4. `sid` は Postgres の `id` をそのまま引き継ぐ。

## 日本語・韓国語の分かち書き

- 日本語は Sudachi。外部サービスとして置ける前提で、`Tokenizer` を 1 か所のモジュール(behaviour)にし、
  インデックス時(書き込み)とクエリ時の両方が必ずそこを通る。片方だけ別の分かち書きだと当たらなくなる。
- 韓国語は未定。`:object/language` で分かち書きの実装を選ぶ形にして、未対応の言語は空白区切りのまま(今の既定)にする。
- 辞書や分かち書き方式を変えたら `tokens` は作り直しになる。元の `content-html` から再生成できるので、保存はするが正本ではない。

## 掃除(remote object の整理)

既存の掃除は 2 つある。`SelfCleanup` は自分のローカル投稿を消す(ピン留めと DM を除外)。`WipeRemote` は remote の note を全部消して再構築する。
ここで決めるのは第 3 の、日常的な「remote object の容量掃除」。

**消さないもの(掃除の対象外)**: remote actor と key、ローカルの object と activity、follow・block・mute、Tombstone、
ローカルのユーザーが関わった remote object(下の保持ルール)。

**保持ルール(どれか 1 つでも当てはまれば残す)。** 「保持の理由」は保存せず、掃除のときに Datalog で導く。
理由を属性として持つと、ピン解除やブースト取り消しのたびに外す書き込みが要り、漏れると消せなくなる。導けば 1 か所で済む。

1. ローカルの actor が書いた(`attributed-to` がローカル)。
2. スレッドにローカルの参加者がいる(object の `root` を引き、同じ root にローカルの object があれば残す。祖先もまとめて残るので返信の文脈が欠けない。root 自身は `root` が自分を指す約束。A←B←C(C がローカル)で B が残り、孤立した Z だけが掃除対象になるのを確認済み)。
3. ローカルの actor が触れた: like・リアクション・ブースト・ブックマーク・ピン・投票・引用・メンション・通知の元。
4. 通報の対象(`reports`)。
5. 猶予内: `touched-at`(なければ `received-at`)が TTL 以内。既定は、フォロー中の著者のもの 90 日、そうでないもの 14 日(環境変数で変える)。読まれる・配られるたびに `touched-at` が更新され、期限が延びる。加えて DB のサイズ予算(環境変数)を超えたら、期限の短い側から前倒しで削る。
   理由: 小さい箱(0.5 OCPU / 512MB)では容量が先に尽きる。ホームやプロフィールで実際に読まれるのは直近で、古い投稿は `touched-at` で生き残るものだけ残せば足りる。90/14 は実際の増加量を見て動かす前提の初期値。

**手順(batch ごとに 1 回払う)。**

1. 候補を `received-at` の範囲(索引)で、TTL より古いものから最大 N 件取る。ここでは全件を見ない。
2. その batch に対してだけ、保持ルール 1〜4 を `not-join` で当てる(batch 1 回分のクエリ)。
3. 残った分を 1 トランザクションで retract。object に付く子(`content` `attachment` `tagging` `reaction` `entry` `vote` `bookmark` `pin` `notification`)を、
   スキーマから「`*/object` を指す ref 属性」を列挙して一緒に消す(`RebuildRemoteNotes.note_fk_refs` と同じ考え方。テストで「ref 属性が消し込み一覧に漏れていない」ことを見る)。
4. 原本は blob 側も GC に回す(下の「大きい raw」)。
5. dry-run は理由ごとの内訳(保持された件数)と、消す件数・子の件数・解放される概算バイトを返す。

**remote の Delete が来たとき**は掃除ではなく Tombstone: 本文・`raw`・子を消して `deleted-at` だけ残す。

**注意(未検証)**: LMDB は retract してもファイルが縮まない。空いたページは再利用されるが、容量を返すには `dtlv copy -c` での詰め直しが要る。
掃除の目的が「ディスクを減らす」なら詰め直しの運用も要る。

## 大きい raw のポインタ

`raw` は必須で、大きいものがある(長い Article、画像付きの collection など)。LMDB は大きい値をオーバーフローページに置くので、
小さい属性と同じ B 木に混ぜるとスキャンと書き込みが重くなる。閾値(案: 4 KiB)を超えたものは Datalevin の外に置き、ポインタだけ持つ。

- **キー**: 内容アドレス `sha256:<hex>`。同じ原本(ブーストや転送で何度も来る)が自然に 1 つになり、読み出し時に hash を検証できる(FEP-8b32 の検証前に原本が壊れていないことも分かる)。
- **属性**: 小さければ `:object/raw`、大きければ `:object/raw-ref` + `:object/raw-size`。どちらか一方だけ。actor・activity も同じ(`raw` / `raw-ref`)。
- **置き場**: `RawStore` の behaviour で、SQLite と S3 互換の 2 つを持つ(環境変数で選ぶ)。SQLite は blob 表(キー、zstd 圧縮した本体、サイズ、作成時刻)で、配信キューが既に SQLite なので運用が増えない。S3 互換は、キー `raw/sha256/<先頭2桁>/<hex>` のオブジェクトで、メディアと同じバケットの別 prefix にもできる。どちらも put/get/exists/delete/一覧(GC 用)だけの小さい契約にする。
- **書き込みの順**: ①blob を put(内容アドレスなので冪等)②Datalevin にポインタを transact。途中で落ちても「参照されない blob」が残るだけで、データは壊れない。
- **GC**: Datalevin 側の `raw-ref` の集合に無く、作成から猶予(例 1 日)を過ぎた blob を消す。掃除の retract の後に動く。
- **読み出し**: `RawStore.get(entity)` が inline か ref かを吸収する。呼び出し側は分岐を書かない(判断は put と get の 2 か所に閉じる)。
- 閾値と圧縮の効果は未計測。実データ(raw の長さの分布)を見てから決める。

## 決定済み(ひなたさん)

- 日本語は分かち書きを入れる(Sudachi、外部に置ける)。韓国語は未定。
- ホームは読み込み時に merge する。`entry` は予備として空のまま。
- 本文は `:object/content-html` と、Misskey のソースがあるときだけ `:object/content-mfm`。

## 未決事項

- 韓国語の分かち書き。
- 掃除の TTL(初期値: フォロー中 90 日、それ以外 14 日)と、大きい `raw` の閾値(案: 4 KiB)を、実データで確かめる。
- LMDB の詰め直し(`dtlv copy -c`)をどう運用に入れるか。
