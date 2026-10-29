<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Datalevin のデータ構造(ひなたさんのドラフトの見直し)

ドラフトを土台に、dtlv 1.2.10 で実際に読み込んで動かし、穴と直し方をまとめた。
改訂版のスキーマは [`elixir/priv/datalevin/schema.edn`](../elixir/priv/datalevin/schema.edn)(166 属性、そのまま読み込める。正本はこの 1 つ)。
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

出来ている(単体テスト済み、どれも今のストアには未接続):

- `SukhiFedi.RawStore`(+ `Config` `SQLite` `S3`): inline / ポインタの振り分け、hash 検証、GC。`raw_blobs` 表はキューの SQLite に起動時に作る。環境変数は `docs/ENV.md`。
- `SukhiFedi.Tokenizer`(+ `Sudachi` `Whitespace`): 言語で切り替え。Sudachi が落ちていても書き込みは止めず、元の文字列で代替(`:degraded`)。Sudachi 側の HTTP 契約は `Tokenizer.Sudachi` の moduledoc。
- `SukhiFedi.Datalevin.SchemaFile`: `priv/datalevin/schema.edn` を読み、構造を検査(全文検索の autoDomain、tuple の部品の定義など)。

まだ(グラフのストア本体を書いてから):

- A 層の Datalog による読み書き、掃除(保持ルールのクエリ)、`tokens` の書き込み、`sid` の採番。

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
