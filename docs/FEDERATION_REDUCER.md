<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# 連合の受け入れを reducer で書く(push と pull を一つの入口にまとめる設計)

> 状態: **設計のみ。実装は変えていない。** ひなたさんが書いた Datalog(push と pull を
> `unified_event` にまとめ、reducer で `db_post` / `db_tombstone` を `next_*` に進め、
> `timeline_view` を作る)を土台に、見つかった穴を直した版を書く。
> 決め待ちは末尾の「決めたいこと」(Q1 から)。

読む順番: [`PULL_FEDERATION.md`](PULL_FEDERATION.md)(pull の線)、
[`FEDERATION.md`](FEDERATION.md)(push の受け入れ)、[`DATALEVIN_SCHEMA.md`](DATALEVIN_SCHEMA.md)(置き場)。
署名まわりは project files の `pull_federation/SIGNATURES.md`、push の仕様ノートは
`federation/push-federation-ste.md`(どちらもリポジトリの外)。

## 読みの前提

- 元の Datalog は、実装の設計図ではなく **受け入れの意味を決める仕様**として読んだ。
  どの DB で動かすか(Datalevin の `q`、Soufflé、Elixir の関数)は、この文書では決めない。
- reducer は **束(バッチ)ごとに一回、一つの取引で**走る。`db_*`(今の状態)と、束の中の
  `unified_event` を入れて、`next_*`(次の状態)が出る。`next_*` を書き込むのと、cursor を進めるのは、
  同じ取引。
- 署名・ポリシー・FEP-8b32 の証明は、reducer の **手前**(入口)で済んでいる。
  [`AP.Ingest.run/3`](../elixir/lib/sukhi_fedi/ap/ingest.ex) がその一か所で、inbox も pull も通る。
  reducer の `actor` は「入口が認めた、送った人」であって、本文に書いてあるだけの名前ではない。
  ([`CODE_STYLE.md`](CODE_STYLE.md) §0: 入口で一度確かめ、中では信じる。)
- 投稿の時刻は、`:object/updated` があればそれ、なければ `:object/published`
  (どちらも epoch からのマイクロ秒の long。[`schema.edn`](../elixir/priv/datalevin/schema.edn))。
  下の `ver` はこの値。
- Datalog は Soufflé の書き方(`.decl`、`!` が否定、`max x : { … }` が集計)。**Soufflé では実行していない**。
  手元に無いため。代わりに、同じ規則を集合演算でそのまま写した小さな Python で、
  下の「確かめた場面」の 9 つが期待どおりになることだけ見ている(このリポジトリには入れていない)。
  実装に進むときに、本物の処理系で通す。

## 元の設計(要約)

```
incoming_push / incoming_pull ──▶ unified_event ──▶ reducer ──▶ next_post / next_tombstone / next_cursor
                                                      ▲                         │
                                       db_post / db_tombstone /                 └──▶ timeline_view
                                       server_sync_cursor
pull_notification ──▶ pull_task(いつ pull するか)
```

良いところ: 入口が二つでも **規則は一つ**(`CODE_STYLE.md` の「安全や速さは一か所に」と同じ形)。
Delete は Create より強い(`!is_tombstoned`)。通知から pull の要否を決める
`pull_task` が単調(`target_seq > last_seq`)。negation はすべて下の層にだけ向いていて、
**stratification は問題ない**(循環が無い)。

## 見つかったこと

| # | 場所 | 起きること | 直し方 |
| --- | --- | --- | --- |
| 1 | `valid_update`、`is_tombstoned` | Update と Delete が、**元の投稿の持ち主かどうか**を見ていない。署名が正しい別の人が、他人の投稿を書き換えたり消したりできる | `owner(obj, who)` を置き、持ち主と `actor` が同じ Update / Delete だけ効かせる |
| 2 | `valid_update`(`db_post` を要求) | Create より先に届いた Update、**同じ束にある Create + Update** が、どちらも捨てられる | 保留の置き場 `db_pending`。束の中の Create も「持ち主が分かる」根拠にする |
| 3 | `next_post` の三本の規則 | 同じ `obj` に `next_post` が複数行できる(古い版と新しい版が両方残る) | 候補 `cand` を作り、`obj` ごとに **最大の `ver` だけ**残す |
| 4 | `seq` | 「pull のサーバーごとの通し番号」と「投稿の新旧」が同じ列に入っている | 列を分ける。流れの番号は `stream` + `seq`(cursor 専用)、投稿の新旧は `ver`(版) |
| 5 | `next_cursor :- pull_task` | まだ取れていないのに、通知の `target_seq` まで cursor が進む。取り損ねが永久に消える。cursor が無いサーバーの初期値も無い | **束の中で実際に届いた最大の `seq` まで**進める。未知の流れは 0 から |
| 6 | `incoming_pull` | `server` の列が無く、`pull_task` と結べない | `stream` の列を足す(下の注意あり) |

もう一つ、直しに伴って見えたこと。

- **Delete が先に来た場合**(Create より前)。元の設計の `db_tombstone(obj)` は誰が消したかを持たないので、
  先に届いた**偽の Delete**(別の actor が、まだ存在しない他人の `obj` を消すと言う)でも、
  本物の Create を永久に止められる。`db_tombstone` に「誰が消したか」を持たせ、後から来た Create の
  持ち主と合わなければ**偽の Delete として無視**する形にした(下の `effective_tombstone`)。

### 6 についての注意: 流れの単位は「サーバー」ではなく「actor」

コーディネーターのレビューは「pull の `seq` はサーバーごとの番号」と読んだが、
今の線([`PULL_FEDERATION.md`](PULL_FEDERATION.md) §2)では **actor ごと**に番号が振られている。
通知の `heads` は actor → 最新の番号、pull の `c[]=<seq>@<actor_uri>`、cursor の表も
`pull_cursors(actor_uri, host, seq)`。サーバーで一本にすると、番号の意味が配信側とずれる。
そこで Datalog の `server` は **`stream`**(いまは actor の URI)と呼ぶ。
サーバー単位にしたいなら配信側の `Log.append` を変えることになる(Q1)。

## 修正版の Datalog

```prolog
// ─── 入口(認められたものだけが来る) ────────────────────────────
// ver: 投稿の版(updated、なければ published)。seq とは別物。
.decl incoming_push(req_id: symbol, action: symbol, obj: symbol, actor: symbol, ver: number)

// stream: 流れの名前(いまは actor の URI)。seq: その流れの中の通し番号。cursor にだけ使う。
.decl incoming_pull(req_id: symbol, action: symbol, obj: symbol, actor: symbol,
                    ver: number, stream: symbol, seq: number)

// 入口で断ったが、流れの番号は越えてよいもの(ポリシー、証明の不一致)。
.decl refused_at_door(stream: symbol, seq: number)

// 完全な頁を取り終えたときの、その頁の head。欠番(削除で引っ込んだ活動)を越える。
// resync のときは「いちばん新しい番号」をここに入れる(履歴は歩かない)。
.decl page_end(stream: symbol, head: number)

// ─── pull を始めるかどうか ──────────────────────────────────
.decl pull_notification(stream: symbol, head: number)
.decl sync_cursor(stream: symbol, seq: number)          // 今の状態

.decl notified_head(stream: symbol, head: number)
notified_head(s, h) :- pull_notification(s, _), h = max x : { pull_notification(s, x) }.

.decl stream_known(stream: symbol)
stream_known(s) :- sync_cursor(s, _).
stream_known(s) :- pull_notification(s, _).
stream_known(s) :- incoming_pull(_, _, _, _, _, s, _).

// 知らない流れは 0 から始める(最初の接触。配信側は新しい 20 件だけ返す)。
.decl cursor_or_zero(stream: symbol, seq: number)
cursor_or_zero(s, c) :- sync_cursor(s, c).
cursor_or_zero(s, 0) :- stream_known(s), !sync_cursor(s, _).

.decl pull_task(stream: symbol, after: number, head: number)
pull_task(s, c, h) :- notified_head(s, h), cursor_or_zero(s, c), h > c.

// ─── 一つの入口 ─────────────────────────────────────────
.decl unified_event(req_id: symbol, action: symbol, obj: symbol, actor: symbol,
                    ver: number, stream: symbol, seq: number)
unified_event(r, a, o, x, v, "", 0) :- incoming_push(r, a, o, x, v).
unified_event(r, a, o, x, v, s, q)  :- incoming_pull(r, a, o, x, v, s, q).

// 同じ内容の二重配信(push と pull、再送)は、ここで一行になる。
.decl ev(action: symbol, obj: symbol, actor: symbol, ver: number)
ev(a, o, x, v) :- unified_event(_, a, o, x, v, _, _).

// ─── 今の状態 ────────────────────────────────────────────
.decl db_post(obj: symbol, ver: number, owner: symbol)
.decl db_tombstone(obj: symbol, by: symbol)       // by: 消すと言った actor
.decl db_pending(obj: symbol, ver: number, actor: symbol)  // 持ち主が分かる前に届いた Update

// ─── reducer ─────────────────────────────────────────────
// 持ち主。保存済みがあればそれ。なければ束の中の Create の actor。
// 同じ束に別々の actor の Create があったら、辞書順で最小の一人(決定的にするだけ。Q5)。
.decl owner(obj: symbol, who: symbol)
owner(o, x) :- db_post(o, _, x).
owner(o, x) :- ev("Create", o, x, _), !db_post(o, _, _), x = min y : { ev("Create", o, y, _) }.

// Delete は「持ち主のもの」か「持ち主がまだ分からないもの」だけ有効。
.decl delete_claim(obj: symbol, by: symbol)
delete_claim(o, x) :- db_tombstone(o, x).
delete_claim(o, x) :- ev("Delete", o, x, _).

.decl effective_tombstone(obj: symbol, by: symbol)
effective_tombstone(o, x) :- delete_claim(o, x), owner(o, x).
effective_tombstone(o, x) :- delete_claim(o, x), !owner(o, _).

.decl is_tombstoned(obj: symbol)
is_tombstoned(o) :- effective_tombstone(o, _).

// Update の候補。保存済みの保留と、束の中のもの。
.decl upd(obj: symbol, ver: number, actor: symbol)
upd(o, v, x) :- ev("Update", o, x, v).
upd(o, v, x) :- db_pending(o, v, x).

// 版の候補。ここには複数行が入る。選ぶのは next_post。
.decl cand(obj: symbol, ver: number, actor: symbol)
cand(o, v, x) :- db_post(o, v, x), !is_tombstoned(o).
cand(o, v, x) :- ev("Create", o, x, v), owner(o, x), !is_tombstoned(o).
cand(o, v, x) :- upd(o, v, x), owner(o, x), !is_tombstoned(o).

// ─── 次の状態 ────────────────────────────────────────────
.decl next_post(obj: symbol, ver: number, owner: symbol)
.decl next_tombstone(obj: symbol, by: symbol)
.decl next_pending(obj: symbol, ver: number, actor: symbol)
.decl next_cursor(stream: symbol, seq: number)

// obj ごとに最大の版が一行だけ。古い Update は勝てない。
next_post(o, v, x) :- cand(o, v, x), v = max w : { cand(o, w, _) }.

next_tombstone(o, x) :- effective_tombstone(o, x).

// 持ち主がまだ分からない Update は残す。(obj, actor) ごとに最新の一つだけ。
next_pending(o, v, x) :-
    upd(o, v, x), !owner(o, _), !is_tombstoned(o),
    v = max w : { upd(o, w, x) }.

// 流れの cursor は、動かさない・進める、のどちらかだけ(戻さない)。
// 進める先は「この束に実際に届いた」最大の seq、入口で断った seq、完全な頁の head。
.decl reached(stream: symbol, seq: number)
reached(s, q) :- incoming_pull(_, _, _, _, _, s, q).
reached(s, q) :- refused_at_door(s, q).
reached(s, h) :- page_end(s, h).

.decl cursor_cand(stream: symbol, seq: number)
cursor_cand(s, c) :- cursor_or_zero(s, c).
cursor_cand(s, q) :- reached(s, q).
next_cursor(s, c) :- cursor_cand(s, c), c = max z : { cursor_cand(s, z) }.

// ─── 読み(timeline)は、next_post を見るだけ ──────────────────
.decl following(follower: symbol, followee: symbol)
.decl timeline_view(user: symbol, obj: symbol, actor: symbol)
timeline_view(user, obj, actor) :- following(user, actor), next_post(obj, _, actor).
```

### 規則ごとの意図

- **`ev` で req_id を落とす**: 同じ (action, obj, actor, ver) が push でも pull でも届いても一行。
  reducer は冪等になる。`req_id` は cursor の記録と監査(`unified_event`)にだけ残る。
- **`owner` を先に決める**: 他の規則はすべて `owner(o, x)` で「この actor はこの投稿の持ち主か」を問う。
  持ち主かどうかの確認は **ここ一か所**(問い 1)。
- **`effective_tombstone` の二本目**: 持ち主がまだ分からない Delete は、持ち主が決まるまで
  `next_tombstone` として残す(先に届いた Delete を忘れない)。持ち主が別の人に決まったら、
  この行は `effective_tombstone` に入らなくなり、次の取引で消える。
- **`cand` と `next_post`**: Create、Update、保存済みを同じ形の候補にして、最大の `ver` を取る。
  「新しい Update が古い Update に負けない」「古い Update が来ても何も起きない」が、
  `valid_update` の特別な条件なしで成り立つ。同じ `ver` の二つ目は、`(obj, ver, owner)` が同じなら一行に畳まれる。
  **同じ `ver` で本文が違う**場合は、この表では見えない(本文は別の置き場)ので、
  実装では先に着いた方を残す(Q4)。
- **`next_pending` を (obj, actor) ごとに一つにする**: 持ち主が確定したとき、偽の持ち主から来た
  最新の Update が、本物の持ち主の Update を押しのけて消えないようにするため。
- **`next_cursor`**: `pull_task` を使わない。**取れた分だけ**進む。
  取れなかった(取引が失敗した)束は `reached` が空になるので、cursor は動かず、次の通知か tick で同じ範囲をもう一度取る。
  元の設計では、通知が来た時点で「取った」ことになっていた。

### 守られていること(不変条件)

1. **持ち主以外の Update / Delete は、状態を変えない。** (`owner` 一か所)
2. **`next_post` は `obj` ごとに高々一行。** (`max` 一か所)
3. **tombstone のある `obj` は `next_post` に出ない。** Update が来ても生き返らない。
4. **cursor は戻らない。** 取れていない範囲を越えない。
5. **同じ束を二度流しても、結果は同じ。** (`ev` と `max` と集合)
6. **取引は束ごとに全部か無か。** `next_post`、`next_tombstone`、`next_pending`、`next_cursor` は一緒に書く。
   これは Datalog の外の約束で、一つでも崩れると 4 が崩れる。

### 確かめた場面(Python の写しで 9 つ)

| 場面 | 結果 |
| --- | --- |
| 別の actor(mallory)が、alice の投稿に Update と Delete を送る | 状態は変わらない |
| Update が Create より先に届き、あとで Create が来る | 保留→Create の束で、Update の版に進む |
| 同じ束に Create と Update | Update の版が `next_post` |
| Create(1)、Update(5)、Update(3) が同じ束 | 版 5 の一行だけ |
| 保存済みの版 4 に、版 2 の Update | 版 4 のまま |
| alice の Delete が先に届き、あとで alice の Create | tombstone のまま、Create は載らない |
| mallory の Delete が先に届き、あとで alice の Create | Create が載る、tombstone は消える |
| cursor 3 の流れに、seq 7 の Create | cursor は 7。束に何も無ければ 3 のまま |
| tombstone のある `obj` に新しい Update | 載らない |

## 今の実装のどこに当てはまるか

今の実装は reducer の形をしていない。規則が **入口ごとに命令的に**散らばっている。
reducer にまとめると、次の三か所が一か所になる。

| reducer の部分 | 今のコード | 違い |
| --- | --- | --- |
| 入口(`unified_event`) | inbox: `Web.InboxController` → `AP.Ingest.run/3`。pull: `PullFederation.Pull.apply_item/4` → 同じ `AP.Ingest.run/3` | 二つの入口が最後の `Ingest.run` で既に合流している。**reducer はこの手前ではなく、`Instructions.execute` の位置**に入る |
| `owner` | `Instructions.Mirror` が `Extract.same_host?/2` で、「投稿の id と actor が同じ**ホスト**」を見る(Create は `attributedTo` も) | 持ち主の**actor 完全一致**ではなく、**ホスト一致**。同じホストの別の actor が他人の投稿を Update / Delete できる(Q2) |
| Update が先に届く | `Mirror.maybe_handle_update/1` は `Repo.get_by(Note, …)` で見つからなければ何もしない | 保留の置き場が無く、**捨てている**。Update(Question) も同じ形 |
| `db_tombstone` | Postgres: 行を消す(tombstone 無し)。Datalevin の graph: `Graph.Ingest.tombstone/2` が `:object/type :Tombstone` と `:object/deleted-at` を付けるが、**未知の `obj` では `{:ok, :unknown}` で何もしない** | Delete が先に来ると、あとの Create が通る。[`PULL_FEDERATION.md`](PULL_FEDERATION.md) §8 の「Delete が pull の Create に負ける」窓と同じ穴 |
| `ver` | Datalevin の `:object/updated` / `:object/published` | 比べる値は schema に既にある。Postgres 版は維持のみで、この設計の対象にしない |
| `next_cursor` | `Pull.advance/2` が `pull_cursors(actor_uri, host, seq)` を、**届いた最大の seq**、または頁が完全なら `heads` まで進める | 元の設計の誤りは、実装にはもう無い。残る差は、入口で断った活動(`:suppressed`、`{:error, _}`)も cursor を越えること。**パースの失敗も越える**(Q3) |
| 知らない流れの初期値 | `pending/1` が `Map.get(cursors, uri, 0)` | 同じ。0 なら配信側が新しい 20 件だけ返す |

Datalevin 側の置き場([`DATALEVIN_SCHEMA.md`](DATALEVIN_SCHEMA.md))に足すもの:

- `db_pending` → 新しい種類のエンティティ(`:pending/object`, `:pending/ver`, `:pending/actor`, `:pending/at`)。
  持ち主が決まったら取り込んで消す。期限で掃く(Q6)。
- `db_tombstone` の「未知の `obj`」→ 本文の無い `:object` を **id だけ**で作って `:Tombstone` にする
  (`:object/id` と `:object/deleted-at`、`by` に当たる `:object/deleted-by`)。
  既存の「掃除では消さない」と合う。
- `owner` → `:object/attributed-to`(既にある)。新しい属性は要らない。

実装を進めるなら、 Datalog のままでは走らせず、まず **Elixir の純関数** `reduce(state, events) :: next_state`
として書き、上の 9 つの場面をテストにするのが素直。そのあと、入口の `Instructions.execute` を
`reduce` の結果を書く形に替える。**一か所に置く**ので、`CODE_STYLE.md` §3 の「単一点の述語」に
`owner?/2` として載せる(§7 のチェック: 重複した確認が無いか)。

## 決めたいこと

各 Q の最後に推奨を書いた。

**Q1. 流れの単位は actor のままでよいか。** 今の線は actor ごと。サーバーごとにするには配信側の
`Log.append` と `heads` の形を変える(互換が切れる)。**推奨: actor のまま**。Datalog の `server`
は `stream` に直した。

**Q2. 持ち主の確認は、actor 完全一致にしてよいか(いまはホスト一致)。**
完全一致にすると、同じホストの別の actor(管理者や Group)が代わりに出す Delete が通らなくなる。
Mastodon と Misskey が、そうした Delete をどの actor 名で出すかは、この文書では確かめていない。
**推奨: 完全一致にして、通らなかった Delete を数えて様子を見る。**

**Q3. パースの失敗や一時的な失敗でも、cursor を進めてよいか。** 今は進む(取り損ねは永久に消える)。
reducer の束が「全部か無か」なら、一時的な失敗(sidecar が落ちているなど)では取引ごと巻き戻し、
cursor を動かさない形にできる。恒久的な拒否(ポリシー、証明の不一致、持ち主違い)と分けて数える。
**推奨: 分ける。** 分け方(どの `{:error, _}` が一時的か)は実装の時に表にする。

**Q4. 同じ `ver` で本文が違う二つが来たら、どちらを残すか。** 推奨: 先に保存した方。
本文の SHA-256 を記録して、食い違いは数えるだけ。

**Q5. 同じ束に、別々の actor の同じ `obj` の Create が来たら。** 辞書順で最小にしたのは決定性のためだけ。
実際は同じホストの別 actor が id を奪い合う異常な場合。**推奨: 両方を拒否して数える**(どちらも信じない)。

**Q6. 保留の Update と、持ち主が分からない Delete の寿命と上限。** 案: 7 日、(obj, actor) ごとに一つ、
全体で 10 万件。期限切れは掃除([`DATALEVIN_SCHEMA.md`](DATALEVIN_SCHEMA.md) の掃除)で消す。
tombstone の「by」の主張は、期限なしで残す(消すと §8 の窓が開く)。

**Q7. 表示の規則(ブロック、ミュート、公開範囲、フォローの承認待ち)は reducer の外でよいか。**
この文書の `timeline_view` は `following` だけ。実際のホームは、`Timelines` の読みで、
これらを後から掛けている。**推奨: reducer は「あるかないか」だけ、「見せるか」は読みの側**
(`CODE_STYLE.md` §5: 読みは SQL/Datalog で絞り、描画は純粋)。

**Q8. Announce、Like、Undo、Move も同じ reducer に入れるか。** この文書は Create / Update / Delete だけ。
pull で運ぶのも `note.created` だけ([`PULL_FEDERATION.md`](PULL_FEDERATION.md) §4)なので、
最初は Note の三つ。**推奨: 三つで始める。**
