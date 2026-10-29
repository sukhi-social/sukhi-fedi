<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Datalevin のデータ構造(ひなたさんのドラフトの見直し)

ドラフトを土台に、dtlv 1.2.10 で実際に読み込んで動かし、穴と直し方をまとめた。
改訂版のスキーマは [`datalevin/schema.edn`](datalevin/schema.edn)(159 属性、そのまま読み込める)。
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

## 移行の道筋

1. A 層の表を `schema.edn` の形で受ける「第二のストア層」を、今の Ecto アダプタ越しではなく Datalog で直接書く(読み取りから)。
2. 読み取り側(タイムライン・スレッド・通知)を Datalog クエリに替え、書き込みは今のアダプタ(Postgres 形)と二重書きして突き合わせる。
3. 一致を見てから書き込みを切り替え、Ecto 形のテーブルを A 層から外す。
4. `sid` は Postgres の `id` をそのまま引き継ぐ。

## 決定済み(ひなたさん)

- 日本語は分かち書きを入れる。元の本文は変えず、分かち書き済みの検索用文字列を `:object/tokens` / `:content/tokens`(全文検索の属性)に別に持つ。クエリにも同じ分かち書きをかける。
- ホームは読み込み時に merge する。`entry` は予備で、今は空のまま。
- `content` は HTML(表示用)。ソースが Misskey の MFM のときは `:object/mfm` にも保存し、HTML だけの投稿は HTML だけ。

## 未決事項

- 分かち書きの実装(どの形態素解析器を Elixir 側に置くか。インデックス時とクエリ時で同じものを使う)。
- 掃除で落とす対象を `:object/retained?` だけで決めてよいか(ローカルの関与の定義)。
- 大きい `raw` の置き場(同じ DB か、別の blob か)。10 万件・短い `raw` の実測しかない。
