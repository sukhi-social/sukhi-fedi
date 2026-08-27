# sukhi-fedi のかたち

> **これが設計の教科書だよー。** 新しく来た人がこのファイルとコードだけ見て、
> ゼロから作り直せる — それが目標。併読するのは
> [`ADDONS.md`](ADDONS.md)（アドオンABIのお約束ごと）と
> [`CODE_STYLE.md`](CODE_STYLE.md)（関心ごとの置き場所のお約束）。
>
> 英語の正本は [`ARCHITECTURE.md`](ARCHITECTURE.md)。ズレてたら英語側を信じてね。

## 1. なにを作ってるの？

`sukhi-fedi` は **ActivityPub な連合SNSサーバー**。Mastodon互換 +
Misskey互換のAPIを喋るよ。ローカルにログインして、Noteを投稿して、
リモートのアクターをフォローして、世界中のFediverseサーバーから
流れてくる投稿を受け取る、あの感じ。

設計の北極星：
**案内人（ゲートウェイ）と配達員（delivery ノード）の Elixir ノードが別々 +
分散Erlang のプラグインノード**、それを **PostgreSQL（真実の源）と
NATS（イベントの通り道）** で束ねる。それ以外は必須依存にしない、って決めてる。
ActivityPub の JSON-LD と HTTP 署名は `SukhiFedi.Fedi` が BEAM の中で
（`fedify.*.v1` の subject 越しに）まかなう。昔そこを担ってた Bun ワーカーは
退役（v0.3.0）── ロールバックとゴールデンフィクスチャ用に残してあるだけ。

## 2. 誰がなにを持ってるの？

```
 ユーザー (HTTPS)                                     他のサーバー (HTTPS)
      │                                                    ▲
      ▼                                                    │
 ╔══════════════════════════════════╗     ╔══════════════════════════════════╗
 ║      elixir — 案内人              ║     ║      delivery — 配達員            ║
 ║  Bandit/Plug / WS streaming      ║     ║  Outbox.Relay                     ║
 ║  OAuth / WebAuthn / session      ║     ║  （LISTEN/NOTIFY → Oban）         ║
 ║  inbox POST 受付 + dispatch      ║     ║  Oban :delivery / :federation     ║
 ║  Outbox の書き込み側（Ecto.Multi）║     ║  外向き HTTP POST + リトライ      ║
 ║  WebFinger / NodeInfo            ║     ║  Collection-Synchronization       ║
 ║  /api/v1 + /api/admin → api ノード║     ║  fedify.sign.v1 で署名            ║
 ╚═════════════════════════════╤════╝     ╚═════════════════════════════╤════╝
                               │                                         │
                               ▼                                         │
                PostgreSQL（真実の源、Ecto経由）◄──── outbox を読む ──────┘
                + outbox（gateway が書き、delivery が読む）
                + delivery_receipts（delivery が書く、冪等性）
                + oban_jobs（共有テーブル、キューは分離。`discarded` が待避線）
                               │
                               ▼
                NATS（素の core ── JetStream は無い、耐久も無い）
                ├─ fedify.*.v1  request/reply — 翻訳 / 署名 / 検証
                └─ stream.*     pub/sub       — streaming の配り
                               │
                ┌──────────────┼─────────────────┐
                ▼                                ▼
 ╔══════════════════════════════════╗  ╔═════════════════════════════╗
 ║  SukhiFedi.Fedi 翻訳家+印鑑職人  ║  ║   api — REST プラグインノード ║
 ║  NATS Micro サービス "fedify"    ║  ║  （:sukhi_api、BEAMノード） ║
 ║    fedify.translate.v1           ║  ║  ゲートウェイから :rpc で叩く ║
 ║    fedify.sign.v1                ║  ║  Mastodon / Misskey API     ║
 ║    fedify.verify.v1              ║  ║  capability を自動登録       ║
 ║    fedify.inbox.v1               ║  ║                             ║
 ║    fedify.ping.v1                ║  ║                             ║
 ║  キューグループ "fedify-workers" ║  ║                             ║
 ║  HTTPサーバーは持たない — NATS専用 ║  ║                             ║
 ╚══════════════════════════════════╝  ╚═════════════════════════════╝
```

**v0.3.0** から、左下のボックス（「翻訳家 + 印鑑職人」）は **Elixir ネイティブの
`SukhiFedi.Fedi`** としてゲートウェイ（と delivery）の中で動くよ。同じ
`fedify.*.v1` を同じ `fedify-workers` キューグループで応答するから、上の図の
トポロジーは変わらない ── 応答する主が Bun サイドカーから BEAM の中に
移っただけ。`bun/` の Bun ワーカーは退役、ロールバックと、ネイティブ移植を
突き合わせるゴールデンフィクスチャの母型として温存。以下で「Bun」って
書いてあるのは「`fedify` サービス（＝いまはネイティブ）」と読んでね。

この分け方で守ってるお約束:

1. **ユーザー向け HTTP はゲートウェイだけが喋る**。`fedify` サービスは HTTP
   サーバーなし、delivery は外向きの inbox POST だけ。
2. **コアスキーマに書き込むのはゲートウェイだけ**（notes, follows, outbox 挿入…）。
   delivery は `outbox / accounts / follows / relays` を読み、
   `delivery_receipts` に書く — 狭くて安定した射影。
3. **外向き配信は全部 delivery ノード** — Bun でもゲートウェイでもない。
   ゲートウェイは `oban_jobs` テーブルに文字列ワーカー名
   （`SukhiDelivery.Delivery.Worker`）で Job を差し込む。`:delivery` キューを
   polling してるのは delivery だけなので、実行もそこだけ。
4. **ゲートウェイ ↔ delivery の通信は Postgres と NATS だけ**。この境界に
   分散 Erlang は引かない。分散 Erlang を使うのは `api/` プラグインノードだけ
   — Mastodon REST の同期応答がほしいから。
5. **`fedify` サービスは JSON-LD と HTTP 署名だけ担当**。その狭い領域を今は
   `SukhiFedi.Fedi` がネイティブに提供。退役した Bun 版（Fedify製）は
   ゴールデンフィクスチャでバイト単位に突き合わせて検証してる。
6. **Mastodon/Misskey REST は api プラグインノードで動く**。ゲートウェイとは
   分散 Erlang の `:rpc` で繋がる — HTTPホップなし、NATSエンベロープなし。

## 3. ディレクトリの地図

```
sukhi-fedi/
├── elixir/                                # 案内人（ゲートウェイのみ）
│   ├── lib/sukhi_fedi/
│   │   ├── application.ex                 # 監視ツリー
│   │   ├── addon.ex / addon/registry.ex   # アドオンABI + 発見
│   │   ├── repo.ex
│   │   ├── outbox.ex                      # Outbox.enqueue / enqueue_multi
│   │   │                                    （書き込み側のみ。Relay と
│   │   │                                    読み取り側は delivery ノード）
│   │   ├── oauth.ex                       # OAuth 2.0 サーバー：register_app、
│   │   │                                    {authorization_code, refresh,
│   │   │                                    client_credentials} grant、
│   │   │                                    verify_bearer、revoke
│   │   ├── accounts.ex                    # Mastodon互換アカウント操作
│   │   │                                    (lookup, update_credentials,
│   │   │                                    counts_for, list_statuses)
│   │   ├── notes.ex                       # create_status / get / delete /
│   │   │                                    context + favourite/reblog/
│   │   │                                    bookmark/pin + counts/viewer flags
│   │   ├── timelines.ex                   # home / public timeline クエリ
│   │   ├── social.ex                      # follow / unfollow / relationships
│   │   ├── relays.ex                      # リレー購読: as:Public への
│   │   │                                    Follow と、accepted な集合
│   │   ├── federation/
│   │   │   ├── actor_fetcher.ex           # リモートactor取得 + ETSキャッシュ
│   │   │   └── fedify_client.ex           # NATS Micro クライアント → Bun
│   │   │                                    （admin のリレー購読で使用）
│   │   ├── schema/                        # Ectoスキーマ（note, account,
│   │   │   │                                follow, boost, reaction,
│   │   │   │                                oauth_app/code/token, …）
│   │   │   └── outbox_event.ex            # `outbox` テーブル
│   │   ├── cache/ets.ex                   # ETS TTLキャッシュ
│   │   ├── ap/                            # ActivityPub ヘルパー
│   │   │   ├── instructions.ex            # inboxアクティビティのディスパッチャ
│   │   │   └── instructions/relayed.ex    # リレーが転送してきたもの
│   │   ├── addons/                        # ファーストパーティのアドオン
│   │   │   ├── nodeinfo_monitor.ex + nodeinfo_monitor/
│   │   │   ├── streaming.ex + streaming/
│   │   │   ├── media.ex
│   │   │   ├── moderation.ex / pinned_notes.ex / web_push.ex
│   │   └── web/                           # コントローラ + plug
│   │       ├── router.ex                  # /oauth/*_ → PluginPlug、
│   │       │                                /uploads/*path → 静的配信 を追加
│   │       ├── rate_limit_plug.ex
│   │       ├── plugin_plug.ex             # api プラグインノードへ :rpc
│   │       ├── inbox_controller.ex
│   │       ├── webfinger_controller.ex
│   │       ├── nodeinfo_controller.ex
│   │       ├── collection_controller.ex   # followers / following collection
│   │       ├── actor_controller.ex
│   │       └── featured_controller.ex
│   ├── priv/repo/migrations/
│   │   ├── core/                          # コアスキーマ
│   │   └── addons/<id>/                   # アドオン別マイグレーション
│   ├── test/                              # unit + integration
│   ├── config/{config,dev,prod,runtime,test}.exs
│   └── mix.exs / Dockerfile
│
├── delivery/                              # 配達員（別の BEAM ノード）
│   ├── lib/sukhi_delivery/
│   │   ├── application.ex                 # 監視ツリー
│   │   ├── repo.ex
│   │   ├── outbox/
│   │   │   ├── relay.ex                   # LISTEN/NOTIFY → Oban dispatch job
│   │   │   └── consumer.ex                # Gnat.sub on sns.outbox.>
│   │   │                                    10種のsubjectをBun translator +
│   │   │                                    Worker fan-out にルーティング
│   │   ├── delivery/
│   │   │   ├── worker.ex                  # Oban :delivery キュー
│   │   │   ├── fan_out.ex                 # 旧式の事前計算ヘルパー（温存）
│   │   │   ├── fedify_client.ex           # NATS Micro クライアント → Bun
│   │   │   ├── followers_sync.ex          # FEP-8fcf
│   │   │   └── follower_sync_worker.ex    # Oban :federation キュー
│   │   ├── schema/                        # コアスキーマの読み取り射影
│   │   │   ├── outbox_event.ex / delivery_receipt.ex
│   │   │   └── account.ex / follow.ex / object.ex / relay.ex
│   │   ├── relays.ex                      # get_active_inbox_urls/0
│   │   ├── prom_ex.ex                     # メトリクスは :4001
│   │   └── release.ex                     # 空（マイグレはゲートウェイ所有）
│   ├── config/{config,dev,prod,runtime,test}.exs
│   ├── test/delivery/worker_test.exs
│   ├── mix.exs
│   └── Dockerfile
│
├── bun/                                   # 翻訳家 + 印鑑職人（退役 v0.3.0。
│   │                                         SukhiFedi.Fedi がネイティブに提供。
│   │                                         ロールバック + ゴールデンフィクスチャ用）
│   ├── services/fedify_service.ts         # ★ NATS Micro サービス本体（唯一のエントリ）
│   ├── handlers/
│   │   ├── build/{note,follow,accept,announce,actor,dm,collection_op,
│   │   │           like,undo,delete}.ts   # 1タイプ1トランスレータ
│   │   ├── verify.ts                      # HTTP署名の検証
│   │   ├── sign_delivery.ts               # HTTP署名の付与
│   │   └── inbox.ts / inbox_test.ts       # 受信アクティビティ → instruction
│   ├── fedify/
│   │   ├── context.ts                     # cachedDocumentLoader
│   │   ├── keys.ts                        # ローカルアクターの鍵ストア（作成用）
│   │   ├── key_cache.ts                   # CryptoKeyキャッシュ（署名パス）
│   │   └── utils.ts                       # signAndSerialize, injectDefined, …
│   ├── addons/
│   │   ├── loader.ts                      # ABIチェック + 有効/無効フィルタ
│   │   ├── types.ts                       # BunAddon + TranslateHandler
│   │   ├── mastodon_api/manifest.ts
│   │   └── misskey_api/manifest.ts
│   ├── package.json                       # TS 6.0.3, @fedify/fedify 1.x,
│   │                                        @js-temporal/polyfill, @nats-io/*
│   ├── tsconfig.json
│   └── Dockerfile                         # oven/bun:1-alpine
│
├── api/                                   # ★ Mastodon/Misskey REST プラグインノード
│   ├── mix.exs                            # 独立した :sukhi_api アプリ
│   ├── lib/sukhi_api/
│   │   ├── application.ex
│   │   ├── capability.ex                  # @behaviour + use マクロ
│   │   │                                    routes は3タプル（公開）か
│   │   │                                    4タプル {…, scope: "…"}
│   │   ├── registry.ex                    # capability の自動発見
│   │   ├── router.ex                      # :rpc 入口
│   │   │                                    + scope: opt がある route 用の
│   │   │                                    Bearerトークン認証plug
│   │   ├── gateway_rpc.ex                 # ゲートウェイに :rpc で戻る
│   │   │                                    :gateway_rpc_impl env で
│   │   │                                    テスト用差し替え可
│   │   ├── pagination.ex                  # max_id/since_id/min_id/limit +
│   │   │                                    Mastodon Link ヘッダ生成
│   │   ├── multipart.ex                   # plug非依存のmultipartパーサ
│   │   ├── views/                         # JSONレンダラ（Mastodon shape）
│   │   │   ├── id.ex                      # snowflake切替準備済みのidエンコーダ
│   │   │   ├── mastodon_account.ex        # Account + CredentialAccount
│   │   │   ├── mastodon_relationship.ex
│   │   │   ├── mastodon_status.ex         # counts + viewer flags via ctx
│   │   │   └── mastodon_media.ex
│   │   └── capabilities/                  # ← ここにファイル置くとエンドポイント増える
│   │       ├── mastodon_instance.ex
│   │       ├── nodeinfo_monitor.ex
│   │       ├── oauth_apps.ex              # /api/v1/apps + verify_credentials
│   │       ├── oauth.ex                   # /oauth/authorize, /token, /revoke
│   │       ├── mastodon_accounts.ex       # accounts/* read + update
│   │       ├── mastodon_follows.ex        # accounts/:id/{follow,unfollow}
│   │       ├── mastodon_statuses.ex       # statuses CRUD + context
│   │       ├── mastodon_interactions.ex   # favourite/reblog/bookmark/pin
│   │       ├── mastodon_timelines.ex      # home / public
│   │       └── mastodon_media.ex          # POST /media + GET/PUT
│   └── Dockerfile
│
├── infra/
│   ├── cloud-init.yaml.tmpl               # 共通VMブート用テンプレ
│   └── terraform/ · terraform-x64-freetier/ # infra-as-code (OCI ARM + x64)
│
├── docker-compose.yml                     # 開発+本番スタック（GHCRイメージ固定）
├── docker-compose.test.yml                # 密閉テストスタック
├── TODO.md                                # 未着手タスクのパンチリスト
└── docs/
    ├── ARCHITECTURE.md                    # 英語正本
    ├── ARCHITECTURE.ja.md                 # ← ここ
    └── ADDONS.md                          # アドオンABI
```

## 4. NATS のトポロジー

### 4.1 NATS には耐久を載せていない

JetStream は使っていないよ。NATS が運ぶのは request/reply（`fedify.*`）と
best-effort な pub/sub（`stream.*`）だけ。どっちも落ちても大丈夫なもの ──
呼んだ側がやり直すか、そのまま見送るか。

耐久はぜんぶ Postgres の仕事。`SukhiFedi.Outbox.enqueue_multi/6` が
それを起こした変更と同じトランザクションで `outbox` 行を書き、
`SukhiDelivery.Outbox.Relay` がその行を Oban ジョブに変えるのも、また一つの
トランザクション。そこから先は `oban_jobs` が運ぶ。あいだにブローカーを
挟むと、増えるのは dual write ── 片方だけがイベントを持っている一瞬 ──
だけで、それは outbox パターンがまさに閉じたかった穴なの。

下の `sns.outbox.*` という名前は、`outbox` 表の *subject* 列として生きてる。
`Outbox.Consumer` が振り分けに使う鍵のまま、ブローカーには出ないだけ。

### 4.2 Subject の命名規則

```
sns.<コンテキスト>.<集約>.<操作>[.<バリアント>]
```

| Subject                            | 向き | 発行元                                       | 消費側                              |
| ---------------------------------- | ---- | -------------------------------------------- | ----------------------------------- |
| `sns.outbox.note.created`          | pub  | `Notes.create_note/1`, `create_status/2`     | `Outbox.Consumer` → fan-out         |
| `sns.outbox.note.deleted`          | pub  | `Notes.delete_note/2`                        | `Outbox.Consumer` → fan-out         |
| `sns.outbox.follow.requested`      | pub  | `Social.request_follow/2`                    | `Outbox.Consumer` → fan-out         |
| `sns.outbox.follow.undone`         | pub  | `Social.unfollow/2`                          | `Outbox.Consumer` → fan-out         |
| `sns.outbox.actor.updated`         | pub  | `Accounts.update_credentials/2`              | _(skip — Bunの`Update(Actor)`まだ)_ |
| `sns.outbox.like.created`          | pub  | `Notes.favourite/2`                          | `Outbox.Consumer` → fan-out         |
| `sns.outbox.like.undone`           | pub  | `Notes.unfavourite/2`                        | `Outbox.Consumer` → fan-out         |
| `sns.outbox.announce.created`     | pub  | `Notes.reblog/2`                             | `Outbox.Consumer` → fan-out         |
| `sns.outbox.announce.undone`      | pub  | `Notes.unreblog/2`                           | `Outbox.Consumer` → fan-out         |
| `sns.outbox.add.created`           | pub  | `Notes.pin/2`                                | `Outbox.Consumer` → fan-out         |
| `sns.outbox.remove.created`        | pub  | `Notes.unpin/2`                              | `Outbox.Consumer` → fan-out         |
| `sns.outbox.oauth.app_registered`  | pub  | `OAuth.register_app/1`                       | _(ローカル監査のみ)_               |

### 4.3 NATS Micro サービス（`fedify`）

サービス名 `fedify`、キューグループ `fedify-workers`。各ゲートウェイの中で
`SukhiFedi.Fedi` がネイティブに応答するから、レプリカを増やせば自動で
ロードバランス。退役した Bun ワーカーも同じエンドポイントを話すので、
ロールバック時は同じキューグループに戻せるよ。

| エンドポイント         | リクエスト                                                   | レスポンス                          |
| ---------------------- | ------------------------------------------------------------ | ----------------------------------- |
| `fedify.ping.v1`       | 生バイト                                                     | そのままエコー（ヘルスチェック）     |
| `fedify.translate.v1`  | `{object_type, payload}`                                     | `{ok:true, data:{…}}`               |
| `fedify.sign.v1`       | `{actorUri, inbox, body, privateKeyJwk, keyId, algorithm?}`  | `{ok:true, data:{headers:{…}}}`     |
| `fedify.verify.v1`     | `{method, url, headers, body}`                               | `{ok:true, data:{ok:bool, …}}`      |
| `fedify.inbox.v1`      | `{raw}`（受信AP活動のパース済JSON）                          | `{ok:true, data:{action, …}}`（命令）|

`translate` のコア `object_type`（`bun/services/fedify_service.ts`）:
`note`, `follow`, `accept`, `announce`, `actor`, `dm`, `add`, `remove`,
`like`, `undo`, `delete`。アドオンは `<addon_id>.<type>` という
名前空間付きキーで追加する — コアキーの上書きは起動時に
`addons/loader.ts` が弾くよ。

サービスディスカバリは NATS Micro が自動で
`$SRV.{PING,INFO,STATS}.fedify` を公開してくれる。

## 5. Transactional Outbox（とっても大事）

ここをサボると「DB insert + NATS pub」が2つの独立書き込みになって、
その間でクラッシュするとイベントが消えるか重複する。だからここは
譲れないパターンなのだ。

### 5.1 スキーマ

マイグレーション `core/20260420000001_create_outbox.exs`:

```
outbox(
  id bigserial PRIMARY KEY,
  aggregate_type text NOT NULL,    -- "note", "follow", …
  aggregate_id   text NOT NULL,
  subject        text NOT NULL,    -- "sns.outbox.note.created" 等
  payload        jsonb NOT NULL,
  headers        jsonb NOT NULL DEFAULT '{}',
  status         text NOT NULL DEFAULT 'pending',  -- pending | published | failed
  attempts       integer NOT NULL DEFAULT 0,
  last_error     text,
  inserted_at    timestamptz NOT NULL DEFAULT now(),
  published_at   timestamptz
)
-- 部分インデックス — published 行が増えてもホットセットが小さいまま
create index(:outbox, [:id], where: "status = 'pending'")
create index(:outbox, [:aggregate_type, :aggregate_id])

-- ステートメント単位のトリガー（行単位じゃない）。
-- bulk INSERT しても 1 INSERT 文あたり NOTIFY は1回だけ。
AFTER INSERT ON outbox FOR EACH STATEMENT EXECUTE FUNCTION outbox_notify();
```

`core/20260420000005_add_hot_path_indexes.exs` で、部分インデックスへの
差し替えと `FOR EACH STATEMENT` トリガーへの切り替えを一気にやってる。
同じマイグレで `notes(visibility, created_at)` (publicタイムライン用)、
`follows(followee_id, state)` / `follows(follower_uri, state)`（FEP-8fcf と
「誰をフォロー？」系のパス用）も入れてる。

`delivery_receipts`（マイグレ `core/20260420000002`）:

```
delivery_receipts(
  id bigserial PRIMARY KEY,
  activity_id  text NOT NULL,   -- ActivityPub Activity id
  inbox_url    text NOT NULL,
  status       text NOT NULL,   -- delivered | failed | gone
  delivered_at timestamptz,
  inserted_at  timestamptz NOT NULL
)
unique_index(delivery_receipts, [activity_id, inbox_url])
```

### 5.2 書き込み側（プロデューサー）

連合に流す必要がある全ての書き込みは `SukhiFedi.Outbox.enqueue_multi/6`
を Ecto.Multi の中でドメインinsertと一緒に使う:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:note, Note.changeset(%Note{}, attrs))
|> Outbox.enqueue_multi(:outbox_event,
     "sns.outbox.note.created", "note",
     & &1.note.id,
     fn %{note: note} -> %{note_id: note.id, …} end)
|> Repo.transaction()
```

DBコミット ⇒ outbox行は永続化。それだけ。

現状の呼び出し元（全部、apiプラグインノードから `SukhiApi.GatewayRpc`
経由で叩かれる — NATS RPCは挟まない）:

- `SukhiFedi.Notes.create_note/1`, `create_status/2`  → `sns.outbox.note.created`
- `SukhiFedi.Notes.delete_note/2`                     → `sns.outbox.note.deleted`
- `SukhiFedi.Notes.favourite/2`, `unfavourite/2`      → `sns.outbox.like.{created,undone}`
- `SukhiFedi.Notes.reblog/2`, `unreblog/2`            → `sns.outbox.announce.{created,undone}`
- `SukhiFedi.Notes.pin/2`, `unpin/2`                  → `sns.outbox.{add,remove}.created`
- `SukhiFedi.Social.request_follow/2`, `unfollow/2`   → `sns.outbox.follow.{requested,undone}`
- `SukhiFedi.Accounts.update_credentials/2`           → `sns.outbox.actor.updated`
- `SukhiFedi.OAuth.register_app/1`                    → `sns.outbox.oauth.app_registered`

ローカル限定の書き込み（フェデらないからoutboxは出さない）:
`Notes.bookmark/2`, `Notes.unbookmark/2`、OAuthのtoken発行/失効/refresh、
セッション参照。

### 5.3 リレー側（outbox消費 → NATS発行）

`SukhiDelivery.Outbox.Relay` は監視ツリー内のシングルトンGenServer:

1. 起動時: `Postgrex.Notifications.listen/2` で `outbox_new` を購読 →
   すぐに1回tickして前プロセスの取りこぼしを拾う。
2. 起床トリガー: トリガーからのNOTIFY、または30秒のフォールバックタイマー。
3. 1tickごとに:
   ```
   SELECT FROM outbox WHERE status='pending'
   ORDER BY id LIMIT 100 FOR UPDATE SKIP LOCKED
   ```
   — `SKIP LOCKED` のおかげで将来複数リレーが同時に走っても安全。
4. 取った行ごとに `SukhiDelivery.Outbox.DispatchWorker` のジョブを1本、
   `Oban.insert_all/2` で。
5. 取った id をまとめて1回の `update_all` で
   `status='published', published_at=now()`。

4 と 5 は、行を取ったのと同じトランザクションの中。だから「published
なのにジョブが無い」も「ジョブがあるのに行が pending」も起きない。
途中で何か上がったらバッチごと巻き戻って、行は `pending` のまま次の
tick を待つ ── リトライの予算は行じゃなくて Oban のジョブが持ってる。

## 6. エンドツーエンドの流れ

### 6.1 ローカルユーザーがNoteを投稿

PR3 + PR5 で end-to-end ライブになった流れ:

```
POST /api/v1/statuses （Bearerトークン付き）
   │  router.ex の /api/v1/*_ にマッチ → PluginPlug → :rpc で api ノード
   │  SukhiApi.Capabilities.MastodonStatuses.create/1
   │  → 認証plugが req.assigns.current_account をスタンプ
   │  → GatewayRpc.call(SukhiFedi.Notes, :create_status, [account, attrs])
   ▼
SukhiFedi.Notes.create_status/2
   Ecto.Multi:
     insert notes
     attach media (note_media join + media.attached_at スタンプ)
     insert outbox(sns.outbox.note.created)
   commit  ──▶ AFTER INSERT STATEMENT TRIGGER が NOTIFY outbox_new
                         │
                         ▼
              SukhiDelivery.Outbox.Relay（起きる）
                         │  行ごとに Oban ジョブ + published 印を
                         │  ひとつのトランザクションで
                         ▼
         SukhiDelivery.Outbox.DispatchWorker (queue :outbox_dispatch)
                         │  → SukhiDelivery.Outbox.Consumer
                         │  actorとrecipient inbox を解決
                         │  （フォロワー + リレー + 各種特例）
                         │  FedifyClient.translate("note", payload)
                         │  → Bun handleBuildNote が署名+シリアライズ
                         ▼
         enqueue_jobs(body, actor_uri, activity_id, inboxes)
           Oban.insert_all — ファン・アウトごとに1 INSERT、
                             inbox数じゃなくて！
                         │
                         ▼ （inboxごとにOban job 1個）
         SukhiDelivery.Delivery.Worker (Oban queue :delivery, max_attempts 10)
          1. delivery_receipts(activity_id, inbox_url) で配信済みか確認
          2. args["raw_json"] からbody復元（DBアクセスなし）
          3. Collection-Synchronization ヘッダを付与
          4. FedifyClient.sign(...) で署名 → NATS Microで Bun に。
             Bun 側は bun/fedify/key_cache.ts のキャッシュされた
             CryptoKey を使うよ
          5. Req.post でinbox_url へ（Finch pool 50×4、ホストごと）
          6. 2xxならdelivery_receipt 記録
          7. エラーならObanの指数バックオフ、最大10回まで
```

ファン・アウトをまたいで不変になる仕事（body encode、フォロワー
ダイジェスト、署名鍵のimport）は、配信1回ずつじゃなくてアクティビティ
1回につき1回に集約されるようになってる。事前計算ヘルパーは
`SukhiDelivery.Delivery.FanOut`（より複雑なfan-outシナリオ用に温存）、
BunのCryptoKey再利用は `bun/fedify/key_cache.ts`。

同じ `Outbox.Consumer` パスが、note 削除 / follow / unfollow /
favourite / unfavourite / reblog / unreblog / pin / unpin もカバー。
それぞれ別の Bun translator キーに対応するけど、Relay → Consumer →
Worker の形は同じ。`sns.outbox.actor.updated` は `Update(Actor)`
ラッパーが Bun 側にまだないので今は `:skipped`（TODO）。

dispatch ジョブの一過性の失敗 ── translator が再起動していて、数秒
のあいだ何にも署名できない、みたいなとき ── は `{:error, _}` で返って、
Oban が `DispatchWorker.backoff/1` でリトライする。11回、およそ27分
かけて間隔を空けて、それでもだめなら `discarded` で休む。そこが待避線。
あとの回が前の回より先へ進めたときは、Worker の `delivery_receipts` が
冪等性を担保してるので大丈夫。

### 6.2 他のサーバーが私たちのinboxに配達

```
POST /users/alice/inbox  （外部のMastodon）
   │
   ▼
Elixir InboxController（生ボディとヘッダをキャプチャ）
   │
   ▼
FedifyClient.verify(%{raw: body})
   │   NATS Micro → fedify.verify.v1 → Bun handleVerify
   │   {ok: true} or {ok: false}
   ▼
FedifyClient.inbox(%{raw: body})
   │   NATS Micro → fedify.inbox.v1 → Bun handleInbox
   │   Instructionsマップが返ってくる
   ▼
Instructions.execute(instruction)
   │   Follow / Accept / Create(Note) / Announce / Like / Delete / Undo
   │   + FEP-8fcf: リクエストにCollection-Synchronizationヘッダが
   │     付いてたら FollowerSyncWorker を積んで follows テーブルを整合
   ▼
DB書き込み + （時々）Oban ジョブ（例えば Accept を返送）
   │
   ▼
202 Accepted
```

`Instructions.execute/1` は他にも、入ってくる`Delete`でローカルの
objectミラーを掃除したり、`Undo(Follow)`でfollow行を消したりする。
DMは`visibility = "direct"`のローカルnoteにマテリアライズされて、
会話の参加者も記録される。

**分かっているのは、署名した人であって、actor ではない。**
`execute/3` は HTTP 署名の鍵の持ち主のホストを取って、アクティビティの
`actor` と突き合わせる。同じホストなら、中身はその actor 自身の言葉
だから、全部のハンドラが走る。違うホストなら転送されてきたもので、
自分で resolve と再取得をやり直すハンドラだけが走る。

ひとつだけ、転送されても消えないものがある。**FEP-8b32 の
Object Integrity Proof**。`Fedi.Oip.verify_inbound/1` は inbox の
POST ごとに走り（suspend の判定より後なので、停止中のピアに鍵を
取りに行かされることはない）、proof の鍵の `controller` が
アクティビティ自身の `actor` であることまで確かめる。壊れた proof は
401 — HTTP 署名だけの扱いに黙って落とすことはしない。通った proof は
`author_signed?` として下へ渡る。転送された中身について持てる、
たったひとつの事実 — 誰が運んできたにせよ、著者がこのバイト列に
署名した、ということ。

**リレー。** リレーの購読は、`as:Public` への外向き `Follow`
（`SukhiFedi.Relays`、管理は `/admin/relays`、署名するのは参加した
管理者本人 — このサーバーにインスタンス actor は無い）。リレーが
`Accept` を返したら、その inbox は外向きの配達先に加わり
（`Relays.get_active_inbox_urls/0`、読むのは delivery ノード）、その
ホストは受け側の *出どころ* として通される（`Relays.accepted_host?/1`）。
リレーが転送してくるものは全部、上の「転送されてきた」枝に落ちるので、
`AP.Instructions.Relayed` が信じかたを決める:

* `author_signed?` なら、中身はそのまま著者の言葉なので、公開の
  `Create` は `Instructions.Mirror` に直接渡す — 往復なし。いま
  proof を付けてくるのは fedify 系だけなので、速い道ではあるけれど、
  まだ多数派の道ではない。
* そうでなければ、ミラーする前に origin から取り直す。転送 1 件につき
  署名付き GET が 1 回 — これが「リレーは知らせを運ぶだけで、権威は
  持たない」ことの値段。

`Announce` に付いた proof は Announce を保証するだけで、指している
note のことは何も言わないので、そちらは常に取りに行く。転送された
`Update`/`Delete` はどちらの道でも捨てる。削除は取りに行っても
確かめられない（404 は、origin が一時的に壊れているときにも返る）し、
署名された文書は誰にでも再送できるから — どちらもリレーに持たせて
いいボタンではない。ミラーした note が出るのは連合の公開タイムライン
で、誰かのホームには入らないし、メンション通知も立てない。ローカルの
誰かに向いたメンションは、著者のサーバーがその人の inbox に直接
配達してきて、そっちが信頼される道を通るから。

### 6.3 WebFinger（ローカルアクター探索）

```
GET /.well-known/webfinger?resource=acct:alice@example.tld
   ▼
WebfingerController（Elixir、Bunは呼ばない）
   1. acct をパース → username, domain
   2. domain == 自分のドメイン:
        Accounts.get_account_by_username/1
        JRDを組み立て（subject, links: self → actor URL）
        ETS :webfinger テーブルにキャッシュ（10分TTL）
   3. それ以外: 404（他所のwebfingerはプロキシしない）
```

### 6.4 NodeInfo

```
GET /.well-known/nodeinfo            → ディスカバリJSON（/nodeinfo/2.1へのリンク）
GET /nodeinfo/2.1                    → 静的情報（version, software, usage）
   ▼
NodeinfoController（Elixir、純関数）
```

### 6.5 followers / following コレクション

`GET /users/:name/followers` と `GET /users/:name/following` は
`SukhiFedi.Web.CollectionController` がJOIN 1発の
`Social.list_followers/2` / `Social.list_following/2` で返す —
アカウント情報を1件ずつ取りに行くようなN+1はなし。

## 7. アドオンシステム

3つの層それぞれがアドオンコードを持てる。同じidを宣言して、
`ENABLED_ADDONS` / `DISABLE_ADDONS` 環境変数を共有するよ。

### ゲートウェイ側（`elixir/lib/sukhi_fedi/`）

```elixir
defmodule SukhiFedi.Addons.Streaming do
  use SukhiFedi.Addon, id: :streaming
  @impl true
  def supervision_children,
    do: [SukhiFedi.Addons.Streaming.Registry, SukhiFedi.Addons.Streaming.NatsListener]
end
```

`SukhiFedi.Addon.Registry` が起動時に、コンパイル済みモジュールから
`@sukhi_fedi_addon` という永続属性を持ってるやつを全部探して、
各アドオンの `abi_version` のメジャーがコア（`"1"`）と合うか確認、
enable/disableフィルタをかけて、監視の子プロセスとNATS購読を返す。
メジャーバージョンが合わないと起動時にクラッシュ（それで安全）。
`priv/repo/migrations/addons/<id>/` のマイグレーションはリリース時に
アドオンごとに走る。

### Bun側（`bun/addons/`）

```ts
const myAddon: BunAddon = {
  id: "my_addon",
  abi_version: "1.0",
  translators: { "my_addon.widget": handleBuildWidget },
};
export default myAddon;
```

`bun/addons/loader.ts` の静的リストに登録（Bunのimportはコンパイル時
なのだ）。アドオンは `fedify.translate.v1` に
`<addon_id>.<type>` 名前空間で新しいキーを足せる。
**コアのトランスレータは上書きできない**ようになってる。

### APIプラグインノード側（`api/lib/sukhi_api/capabilities/`）

1ファイル1 capability。`use SukhiApi.Capability, addon: :mastodon_api`
でアドオンにタグ付け。タグなしはコア扱い（常に有効）。
`SukhiApi.Registry` が起動時に
`:application.get_key(:sukhi_api, :modules)` で発見して、同じ環境変数で
フィルタ。DBアクセスは `gateway_rpc` でゲートウェイに戻るから、
プラグインノードは自前のEctoプールを持たない。

ABIの全容は `docs/ADDONS.md` 参照ー。

## 8. APIプラグインノード（分散Erlang）

Mastodon / Misskey の REST 面は `api/` 配下の **独立BEAMノード**
として走る。ゲートウェイは `SukhiFedi.Web.PluginPlug` 経由で
`:rpc.call/5` する — HTTPホップなし、NATSエンベロープなし、
docker-composeネットワーク上の素のErlang Distributionだけ。

```
クライアント ──HTTPS──▶  Elixir ゲートウェイ (node gateway@elixir)
                         └─ router が "/api/v1/*_" または "/api/admin/*_" にマッチ
                            └─ SukhiFedi.Web.PluginPlug
                               └─ :rpc.call(api@api, SukhiApi.Router, :handle, [req])
                                                │
                                                ▼
                                        api BEAMノード (node api@api)
                                        SukhiApi.Registry（自動発見）
                                          └─ Capabilities.MastodonInstance
                                          └─ Capabilities.<他にも…>       ← 1ファイル = 1機能
```

**リクエスト / レスポンス契約**（`SukhiApi.Capability` moduledoc 参照）:

```
req  :: %{method: "GET" | "POST" | …, path: "/api/v1/…",
          query: "a=1&b=2", headers: [{k, v}], body: binary}
resp :: %{status: 200, body: iodata, headers: [{k, v}]}
```

**エンドポイント追加の手順** — `api/lib/sukhi_api/capabilities/` に
ファイルを置くだけ:

```elixir
defmodule SukhiApi.Capabilities.InstancePeers do
  use SukhiApi.Capability, addon: :mastodon_api  # コアなら省略

  @impl true
  def routes, do: [{:get, "/api/v1/instance/peers", &peers/1}]

  def peers(_req), do: {:ok, %{status: 200, body: "[]",
                               headers: [{"content-type", "application/json"}]}}
end
```

以上、ぜんぶ。ルータ編集もマニフェスト更新もいらない。
`use SukhiApi.Capability` マクロがモジュール属性を永続化して、
`SukhiApi.Registry` が実行時に
`:application.get_key(:sukhi_api, :modules)` をスキャンして拾う。

**認証付きエンドポイント** は `routes/0` で4タプルを返し、`scope:`
キーワードを付ける:

```elixir
def routes do
  [{:get, "/api/v1/accounts/verify_credentials", &show/1, scope: "read:accounts"}]
end

def show(req) do
  %{current_account: account, current_app: app, scopes: scopes} = req[:assigns]
  …
end
```

`SukhiApi.Router` が `Authorization: Bearer <token>` ヘッダを parse して、
`SukhiFedi.OAuth.verify_bearer/1` を `GatewayRpc` 経由で叩いて scope の
superset チェックを通したら、`req.assigns.current_account` /
`current_app` / `scopes` をスタンプしてからハンドラに渡す。
トークンなし → 401、scope 不足 → 403、ゲートウェイ到達不能 → 503。
3タプルrouteは無認証のまま。

**テスト用の差し替え**: `SukhiApi.GatewayRpc.call/3,4` は
`Application.get_env(:sukhi_api, :gateway_rpc_impl)` を最初に見るから、
テストはここに「キャンド応答を返すだけのモジュール」を差し込めば
分散Erlang一切なしでrouter全部回せる。本番はそのまま `:rpc.call`。

**失敗モード**:

- `plugin_nodes` 未設定 → 503 `{"error":"plugin_unavailable"}`
- `:rpc` 時にノード到達不能 → 503 `{"error":"plugin_rpc_failed"}`
- リモートノード側でハンドラがクラッシュ → 向こうで catch して 500
- どのcapabilityにも該当しないパス → 向こうで 404
- トークン検証 失敗 → 上の認証plugから 401 / 403 / 503

### 8.1 Mastodon互換 REST 表面（PR1〜PR3.5）

全部 `addon: :mastodon_api` でタグ。capability は
`api/lib/sukhi_api/capabilities/`、JSONレンダラは
`api/lib/sukhi_api/views/`。

| Capability                       | ルート                                                                                                                              |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `MastodonInstance`               | `GET /api/v1/instance`                                                                                                              |
| `OAuthApps`                      | `POST /api/v1/apps`, `POST /api/v1/apps/verify_credentials`                                                                         |
| `OAuth`                          | `GET /oauth/authorize`（HTMLフォーム）, `POST /oauth/authorize`, `POST /oauth/token`（auth code / refresh / client_credentials）, `POST /oauth/revoke` |
| `MastodonAccounts`               | `verify_credentials`, `update_credentials`, `lookup`, `relationships`, `:id`, `:id/statuses`, `:id/followers`, `:id/following`     |
| `MastodonFollows`                | `:id/follow`, `:id/unfollow`                                                                                                        |
| `MastodonStatuses`               | `POST /api/v1/statuses`, `GET /:id`, `DELETE /:id`, `GET /:id/context`                                                              |
| `MastodonInteractions` (PR3.5)   | `:id/{favourite,unfavourite,reblog,unreblog,bookmark,unbookmark,pin,unpin}`, `GET /api/v1/{bookmarks,favourites}`                 |
| `MastodonTimelines`              | `GET /api/v1/timelines/home`, `GET /api/v1/timelines/public`                                                                        |
| `MastodonMedia`                  | `POST /api/v1/media`（同期）, `POST /api/v2/media`（非同期 202）, `GET /api/v1/media/:id`, `PUT /api/v1/media/:id`                 |

ビュー: `MastodonAccount`（自分には `render_credential`）,
`MastodonRelationship`, `MastodonStatus`（`%{counts:, viewer:}` ctx で
カウント+viewerフラグ）, `MastodonMedia`, `Id`（snowflake切替準備済みの
idエンコーダ）。ページネーションは `SukhiApi.Pagination` が
`?max_id=`/`?since_id=`/`?min_id=`/`?limit=` を読んで Mastodon 風の
`Link: <…>; rel="next"` ヘッダを組み立てる。

OAuth テーブル（`oauth_apps`, `oauth_authorization_codes`,
`oauth_access_tokens`）は `core/migrations` 配下 — addon の中じゃない。
将来の `:misskey_api` addon が同じ token store を使えるように、かつ
addonをまたぐ FK を禁じてる `ADDONS.md §Migrations` のルールを
壊さないように、こっちに置いた。トークンは SHA-256 ハッシュで保存し、
平文は発行時の1回だけ返す。

### 8.2 サーバー側メディアアップロード

`POST /api/v1/media` は `multipart/form-data` を受ける（apiノードは
Plugパイプラインを動かしてないので、自前の `SukhiApi.Multipart` で
パース）。capability はファイルバイト列を `:rpc` でゲートウェイに
渡し、`SukhiFedi.Addons.Media.create_from_upload/3` が S3 互換ストレージ
（本番では rustfs accessory）へ PUT する。ゲートウェイの
`/uploads/<key>` はそこから proxy して返すので、バケットの場所と
credential は外に出ない。ディスクに置く道は無い ── S3 が未設定なら
`{:error, :s3_not_configured}` で止まる。インライン上限は **8 MiB**
（分散Erlang転送に乗る範囲）。それより大きいファイル向けの
presigned-URL フローは `TODO.md`。

既存の `generate_upload_url/3`（S3/R2 presigned PUT）はクライアント
直接アップロードに将来使うために残してあるけど、まだcapability化
されてない。

## 9. 可観測性（OpenTelemetryなし）

- **メトリクス**: `PromEx` が4000番ポートで `/metrics` 公開。外部の
  scraper（セルフホストPrometheus、Grafana Cloud Free、等々）が
  引きに来る。最初から Ecto / Oban / Plug / BEAM system メトリクスが
  揃ってる。独自メトリクスは `:telemetry.execute` +
  `telemetry_metrics`。
- **ダッシュボード**: レポジトリには入れない。ローカルか managed の
  Grafanaを `http://<host>:4000/metrics` を食べてるPrometheusに
  向けてね。
- **トレース**: **あえて入れてない**。OpenTelemetry / Jaeger / otelcol を
  却下した理由は (a) Fedify側のOTel統合が重い、(b) 私たちの規模だと
  運用コストが割に合わない、(c) `request_id` 付きの構造化ログで
  「道を辿り直す」用途はカバーできる。`elixir/mix.exs` に
  `opentelemetry_*` 依存がゼロなのは確信犯。
- **構造化ログ**: 各コントローラ/ワーカーは `Logger.metadata(request_id: …)`
  を付ける。あとで `grep` でインシデントを再現できるから。

機能追加のたびに出していくカスタムメトリクス:

| メトリクス                          | 種類      | 出す場所             |
| ----------------------------------- | --------- | -------------------- |
| `sukhi_outbox_pending_count`        | gauge     | `Outbox.Relay` tick  |
| `sukhi_outbox_publish_rate`         | counter   | `Outbox.Relay`       |
| `sukhi_delivery_success_rate`       | counter   | `Delivery.Worker`    |
| `sukhi_delivery_failure_rate`       | counter   | `Delivery.Worker`    |
| `sukhi_fedify_latency_ms`           | histogram | `FedifyClient`       |
| `sukhi_inbox_request_rate`          | counter   | `InboxController`    |
| `sukhi_delivery_pool_utilization`   | gauge     | Finch telemetry      |

## 10. 環境変数

| 変数                                 | サービス    | デフォルト                | 用途                                |
| ------------------------------------ | ----------- | ------------------------- | ----------------------------------- |
| `DB_HOST` / `USER` / `PASS` / `NAME` | Elixir      | （本番では必須）          | Postgres接続                        |
| `DB_POOL_SIZE`                       | Elixir      | `10`                      | Ectoプールサイズ                    |
| `NATS_HOST` / `NATS_PORT`            | Elixir      | `127.0.0.1:4222`          | NATSクライアント                    |
| `NATS_URL`                           | Bun         | `nats://localhost:4222`   | NATSクライアント                    |
| `PLUGIN_NODES`                       | Elixir      | `api@api` (compose)       | `:rpc` 対象ノード（空白・カンマ区切り） |
| `RELEASE_COOKIE`                     | Elixir+api  | `sukhi_fedi_dev_cookie`   | 分散Erlang共有シークレット          |
| `DOMAIN` / `INSTANCE_TITLE`          | api         | `localhost:4000` / `sukhi-fedi` | NodeInfo / WebFinger の出力 |
| `ENABLED_ADDONS` / `DISABLE_ADDONS`  | 全部        | `all` / `""`              | カンマ区切りのアドオンid            |
| `S3_BUCKET` / `S3_ENDPOINT` / `S3_ACCESS_KEY` / `S3_SECRET_KEY` / `S3_REGION` / `S3_PUBLIC_URL` | Elixir | _(未設定)_ | メディアの置き場（本番では rustfs）。未設定だとアップロードは通らない |

## 11. ローカルで動かす

### 開発用スタック
```bash
# postgres + nats + gateway + delivery + api（bun は退役、
# `disabled` プロファイルの裏）。ホストから届かせる最小の .env と
# ソースビルドの override は README のクイックスタート参照。
docker-compose up --build
# http://localhost:4000             — Elixir ゲートウェイ（SPA + Mastodon API）
# http://localhost:4000/metrics     — PromEx（外からスクレイプしてね）
```

### テスト用スタック（密閉、ポートを分けてある）
```bash
docker-compose -f docker-compose.test.yml up -d
# Postgres : localhost:15432   (db: sukhi_fedi_test, tmpfs なので毎回まっさら)
# NATS     : localhost:14222   (monitor: :18222)
# fedify-service : NATS Micro キュー "fedify-workers"
```

### テスト実行

```bash
# Elixirユニットテスト（密閉、ライブ依存なし）:
cd elixir && mix test --no-start

# Elixir統合テスト（docker-compose.test.yml 起動済みで）:
cd elixir && mix test --only integration

# Bun テスト:
cd bun && bun test

# Bun 全体の型チェック（TS 6.0.3 を tsc 経由で）:
cd bun && bun run check
```

## 12. 水平スケールの姿勢

- BEAM ノードは **ステートレス**設計 — 状態は全部PostgresかNATSに。
  `mix release` + `docker compose up --scale gateway=N` でゲートウェイ
  複製が増える。ネイティブの `fedify.*.v1` はその各ノードの中で動いて、
  NATS Micro のキューグループ `fedify-workers` で自動ロードバランス。
- `Outbox.Relay` の `FOR UPDATE SKIP LOCKED` のおかげで複数リレーを
  同時に走らせても安全（各自が別のバッチを取る）。
- ETSキャッシュ（WebFinger JRD、リモートactor fetch、fedify サービスの
  import済み CryptoKey）は **ノードローカル**。ミスしたらPostgresかHTTP fetchに
  フォールバックするから、ノード間でキャッシュがズレても壊れない。
- 将来の `SUKHI_ROLE=inbox|api|worker|all` スイッチが入ると、
  同じイメージのまま起動するサブツリーを切り替えられる。例えば
  DoS時に inbox受付だけを専用ノードに逃がせる、みたいな使い方。

## 13. リファクタの哲学（strangler-fig）

コードベースはずっと小さな、常にマージ可能な段階を積み重ねて
今の形になってる。各段階で `mix test` と `bun test` を緑に保って、
独立してリリースできた。

```
0   足場づくり                ✅ 完了
1   Outbox インフラ           ✅ 完了
2   NATS Micro（追加のみ）    ✅ 完了
2-b 古い ap.* の除去          ✅ 全部 fedify.* に統合、ap.* surface と bun/main.ts も削除済
3   HTTP統合                  ✅ WebFinger / NodeInfo / ActorFetcher / RateLimitPlug
3-b Bun HTTP の除去           ✅ bun/lib/ 削除（Honoサーバーなし）、bun/api/ ハンドラ削除
3-c プラグインAPI (api/)      ✅ 分散Erlangのプラグインノード、capability自動登録
4   配信をElixirに            ✅ Worker が FedifyClient + delivery_receipts を使用
4-b Finchプール + E2E        ✅ Finchプール 50×4 per host
5   神モジュール分割          ✅ db_nats_listener を 5つの Nats.* に分割、
                                 その後 db.* surface 自体を呼び元なしで削除
6   docs + デッドコード掃除   ✅ 古いdocs削除、README / ARCHITECTUREが揃ってる
7   ホットパス最適化          ✅ FanOut事前計算、Oban.insert_all、
                                 Outbox.Relay のバルク update_all、
                                 outbox部分インデックス、STATEMENTトリガー、
                                 notes / follows インデックス、
                                 Bun CryptoKeyキャッシュ
8   strangler-fig 一掃        ✅ リファクタ前の web controller (16個)、
                                 ap.* / db.* surface、mfm / key_cache addon、
                                 streaming HTTP controller を削除。
                                 context module は live な関数だけに圧縮
9   Mastodon API MVP          ✅ OAuth 2.0 + Bearer 認証plug、accounts /
                                 statuses / timelines / media / interactions
                                 capability、Outbox.Consumer が
                                 note/follow/like/announce/add/remove subjects を
                                 Bun translator + Worker fan-out に流す。
                                 残ったやつは TODO.md（Misskey API、
                                 streaming WS、push など）。
```

機能を追加するときは、まず自分がどのステージに属するのか、
そのステージの完了を待った方がいいのか考えるんだよー。`TODO.md` に
未着手の作業リストがあるから、暇なら拾って〜。

---

*この日本語版は [`ARCHITECTURE.md`](ARCHITECTURE.md) の翻訳。
内容がズレたら英語側を正とするね。*
