<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Pull Federation: まとめて取る(フォロー分の一括 pull)

> 状態: **後回し(TODO)。** データベースの設計([`FEDERATION_REDUCER.md`](FEDERATION_REDUCER.md) の「データベースの設計」)が先。
> この文書は、そのあとに取りかかるときの下書き。設計のみで、実装は変えていない。 [`PULL_FEDERATION.md`](PULL_FEDERATION.md) の拡張案。
> 受け取った活動の扱いは [`FEDERATION_REDUCER.md`](FEDERATION_REDUCER.md) に従う。
> 決め待ちは末尾の「決めたいこと」(Q1 から)。

## 読みの前提

ひなたさんの一言を、次のように読んだ。違えば直す。

> 相手のサーバーに、**このインスタンスがフォローしている人**を一気にちょうだいと頼む。
> 相手とリレーの関係にあるなら、**リレーしているという証**を添えて、**相手のサーバーがフォローしている人の分**も頼む。
> 取り方は、**アクターごとの ETag**を持っていって、「ここまで持っているよ」と照らす。

つまり今の pull(通知を受けて、通知に出た actor の分だけを cursor で取る)に、
**こちらから、持っている ETag を並べて、変わった分だけ返してもらう**入口を足す。
通知はヒント(きっかけ)のまま。この入口は「取り損ねを埋める」「フォローした直後に過去を埋める」
「リレー経由で広く取る」ための**照合**として使う。

## 1. 二つの範囲(scope)

| scope | 何が返るか | 認可 |
| --- | --- | --- |
| `follows` | 相手のホストの actor のうち、**こちらのホストに一人でもフォロワーがいる**もの | 相手の持つフォロー表だけで足りる。証は要らない(push の宛先と同じ根拠) |
| `relayed` | 相手のホストの利用者が**フォローしている actor**(相手のホストの外の actor)の公開の投稿 | **リレーの証**(§3)。相手の管理者が許した相手だけ |

`follows` は今の pull を一括にしたもの。`relayed` は新しい約束で、**公開の投稿だけ**、
フォロー関係の向き(誰が誰をフォローしているか)は返さない。

## 2. 線(ワイヤ)

能力の宣言は今と同じ形で、`endpoints` に `pullBulk` を足す
([`PULL_FEDERATION.md`](PULL_FEDERATION.md) §1 の規則: https、actor の `id` と同じホスト、512 バイト以内)。

```
POST <the origin's pullBulk>
Content-Type: application/json
Content-Digest: sha-256=:…:
Signature-Input / Signature: RFC 9421(@method, @target-uri, @authority, content-digest; 有効 60 秒)

{"scope":"follows",
 "have":{"https://origin.example/users/a":"s.1234",
         "https://origin.example/users/b":"o.Qm9…"},
 "next":null}
```

- `have` は **actor → ETag**。持っていない actor は載せない(=最初の接触。新しい 20 件だけ返る)。
  ETag は既存の二種類(順序つき `s.<n>`、不透明 `o.<random>`。プロトタイプの `Etag`)。
- 一回の上限は **256 actor**、本文 32 KiB。超える分は呼び手が分けて送る。
- 返りは NDJSON(一行 = 一つの actor の枠)。**変わっていない actor は載らない**:

```
{"actor":"https://origin.example/users/a","etag":"s.1240","activities":[{…FEP-8b32 の証つき…}],"more":false}
{"actor":"https://origin.example/users/b","resync":true,"etag":"o.Zm9…"}
{"next":"<opaque>"}      // まだ続きがある(頁の区切り)
```

- `scope: "relayed"` は `"relay": <証>` を足す(§3)。返る actor は相手のホストの外のものを含む。
- 返りの順番は、actor ごとに seq の昇順。**actor をまたぐ順序は約束しない**。
- 署名の約束は project files の `pull_federation/SIGNATURES.md` と同じ(各活動に自分の証、要求は短い窓の 9421、ETag は無署名のヒント)。
  POST にするのは `have` が長く、GET の URL に収まらないため(Q1)。

## 3. リレーの証

「このサーバーとリレーしている」を、**相手が自分で確かめられる形**にする。三つ考えた。

| 案 | 中身 | 長所 | 短所 |
| --- | --- | --- | --- |
| A. 発行された許可証 | 相手(origin)が発行した `RelayGrant`(`issuer`、`holder`=こちらのホスト、`scope`、`expires`)に、origin の署名。呼び手が付ける | origin は**自分の署名を見るだけ**(表を引かない)。期限と取り消しが書ける | 発行・更新の手順が要る |
| B. 今のリレー購読 | origin のリレー表(`Schema.Relay`)に、こちらが購読者として載っているかを引く | 新しい約束がいらない | 証にならない(呼び手は何も付けない)。購読は Mastodon 型リレーの意味で、pull の認可とは別物 |
| C. 相互のフォロー | 双方の instance actor が互いをフォローしている | ActivityPub の既存の約束だけ | リレー(広く取る)の許可と意味が混ざる |

**推奨は A。** origin の管理者が「このホストには広く渡してよい」と決めた事実が、署名つきで残る。
`RelayGrant` は無署名の ETag と違い**認可**なので、短くない期限(例 30 日)と、
origin 側の取り消し一覧を持つ。呼び手の署名(§2)は別に要る(許可証を盗んでも使えない)。
どの案でも、origin は `scope: "relayed"` を**既定で断る**(`PULL_FEDERATION=off` と同じ「何もしない」側)。

### relayed の活動を、どう信じるか

relayed の活動の `actor` は origin のホストの外にいる。今の入口の約束
(「actor のホストが、流れを出したホストと同じ」。[`PULL_FEDERATION.md`](PULL_FEDERATION.md) §2)はそのままでは通らない。
そこで **relayed の活動は、actor 自身の FEP-8b32 の証があるものだけ**通す
(`AP.Ingest` の `proof_verdict` が `:author_signed` のもの)。証が無いもの・確かめられないものは、
origin が言っているだけで actor が言った証にならないので、**黙って捨てずに数えて**落とす。
origin の署名は「origin が送った」ことしか言わない、が理由。

## 4. 受け取る側(follower)

- **何を頼むか**: フォローの表から、ホストごとに「フォローしている actor」を**一度の問い合わせ**で引く
  (`CODE_STYLE.md` §0 の「まとめて払う」)。ETag は `pull_cursors` の `seq` を `etag` 文字列に広げて持つ
  (順序つきなら今の `seq` と同じ意味。不透明は等しいかどうかだけ)。
- **いつ頼むか**: 通知の代わりではなく、次の三つのとき。
  (1) フォローが成立した直後(過去を埋める)、(2) 起動後と、長く pull が無かったホストへの照合、
  (3) `relayed` を許されたホストへの定期の取り込み(間隔は Q5)。
  どれも、`Puller` が `pull_pending` を読む今の流れに**「ホストの全部」という種類の仕事**を足すだけにする。
- **入口**: 返った活動は、今と同じく `AP.Ingest.run/3` を通り、
  [`FEDERATION_REDUCER.md`](FEDERATION_REDUCER.md) の `incoming_pull` として束になる。
  流れの名前 `stream` は、**(出したホスト, actor)** にする。relayed では同じ actor の番号が
  origin ごとに別々に振られるため、actor だけでは足りない(reducer 文書の Q1 に反映)。
- **cursor**: reducer の約束どおり、束が書けた範囲まで。`more` が真の actor は、次の呼びで続ける。

## 5. 送る側(origin)

- `Serve` に `bulk/2` を足す。`have` の各 actor について、既存の `Log` を **一度の問い合わせ**で引く
  (`WHERE (actor, seq) > …` を actor の数ぶん繰り返さない)。`Gate` は**一束で一つの枠**を数え、
  総件数にも上限を掛ける(1 回の返りは 500 活動まで、残りは `next`)。
- `follows`: 呼び手のホストにフォロワーがいる actor だけを答える(いない actor を `have` に書かれても、
  存在を教えない。未知の actor と同じ答え=枠なし)。
- `relayed`: 許可証を確かめ、**公開の投稿だけ**、**フォロワーが k 人以上**の actor だけ返す(Q3)。
  どの利用者がフォローしているかは返さない。
- **Delete**: 今は「引っ込んだ活動は欠番」だが、relayed では欠番を信じる理由が弱い
  (別の origin 経由で Create だけ持っている相手がいる)。**Delete は枠の中に `{"type":"Delete"}` として
  載せる**(Q4)。reducer の `db_tombstone` と合う。

## 6. 守られていること

1. 一括でも、`have` に書かれた actor の存在は、権限のない呼び手に漏れない。
2. `relayed` は、origin の許可と呼び手の署名の**両方**が無ければ動かない。許可証だけでは使えない。
3. 受け取った活動は、すべて `AP.Ingest.run/3` を通る。**一括だけの近道は作らない**。
4. 一回の要求の重さには上限がある(256 actor、32 KiB、500 活動)。大きな頼みは頁になる。
5. 通知が無くても動く。通知が来る世界では、通知で足りる分は今までどおり cursor で取る。

## 7. 今の実装との関係

| 部分 | 今 | 足すもの |
| --- | --- | --- |
| 宣言 | `endpoints` の `pullNotify` / `pullStream` | `pullBulk`(`PeerCapabilities` に列を一つ) |
| origin | `Serve`(`c[]=` を 64 まで)、`Gate`、`Log` | `Serve.bulk/2`、`RelayGrant` の確認、フォロワー数の引き |
| follower | `Puller`(通知から)、`Pull.run/1`、`pull_cursors(actor_uri, host, seq)` | 一括の仕事の種類、`etag` 列、ホストごとのフォロー actor の一括引き |
| 認証 | 9421 の GET(`SIGNATURES.md`) | 9421 の POST(`Content-Digest` を署名に含める) |
| リレー | `Schema.Relay`(Mastodon 型の購読) | 許可証(案 A)の発行と、取り消しの一覧 |

Datalevin 側は、フォローの表と `:object/attributed-to` がそのまま使える。
ETag の列と許可証は新しい属性(`:pull/etag`、`:relay-grant/*`)になる。Postgres 版は維持のみ。

## 決めたいこと

各 Q の最後に推奨を書いた。

**Q1. 一括の要求を POST にしてよいか。** 256 actor の URL は長すぎる(1 actor 約 40 バイトで 10 KiB 超)。
GET に近い性質(副作用なし・再送してよい)は保てる。**推奨: POST。**

**Q2. リレーの証は案 A(発行された許可証)でよいか。** B は「証」にならず、C は意味が混ざる。
**推奨: A。** 期限は 30 日、origin 側に取り消し一覧。

**Q3. `relayed` で返す actor の下限(フォロワーが何人以上か)。** 小さい集まりのフォロー(1 人だけ)が、
そのまま相手に分かるのを避けたい。**推奨: 3 人以上。** 数は実データで見直す。

**Q4. Delete を枠の中に載せてよいか。** 欠番のままでは、relayed の Create を持つ相手が消せない。
載せると、Delete が「必ず push」の約束([`PULL_FEDERATION.md`](PULL_FEDERATION.md) §4)に**加えて**pull でも届く形になる。
**推奨: 載せる。** Delete の push は今のまま残す。

**Q5. `relayed` を取りに行く間隔。** 推奨: 15 分ごと、返りが空なら倍々(最長 6 時間)。
通知の無い世界なので、**やさしく**取る方に寄せた。

**Q6. relayed の活動に actor の証が無いとき、本人から取り直してよいか。** 取り直すと、
origin に頼らずに済むが、こちらの外向きの取得が増える。**推奨: 最初は落として数えるだけ。**
数が多ければ取り直しを足す。

**Q7. 流れの名前を (ホスト, actor) にする変更は、既存の `pull_cursors` の主キーに響く。**
(今は `actor_uri` が主キー。)移行は行の追加だけで済む見込みだが、`follows` と `relayed` を
同じ actor が両方から受けるとき、**どちらの番号が正か**を決める必要がある。**推奨: 別々の行として持つ**
(reducer では別の `stream`)。重複は reducer の `ev` が畳む。
