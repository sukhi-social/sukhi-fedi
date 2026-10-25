# TODO

Surface for work still missing. Done items have been pruned —
`git log` is the diary, this file is the punch-list.

Design-deferred items (where to go *next* depends on which way we
turn) live in [`OPEN_QUESTIONS.md`](OPEN_QUESTIONS.md). The two
files are complementary: TODO is "do this", OPEN_QUESTIONS is
"decide this".

---

## 後で拾う polish (2026-05-28 棚卸し)

今日 `locked` の通り道 + ActorJson parity を片付けたとき横に出てきた
小ぶりな項目。痛みは中〜小なので個別 plan を立てて順に。

- [ ] **デフォルトアバターを実 PNG にする.**
      `api/lib/sukhi_api/views/mastodon_account.ex` の `@default_image`
      は 1×1 透明 PNG の data URL。`/static/missing.png` を本当に
      置いて差し戻す。「画像見えてる」と「avatar 未設定」を区別
      できるようにしたい。
- [ ] **avatar/header serve の cache + presigned 化.**
      `serve_upload/2` が `ExAws.S3.get_object` を BEAM プロセスで
      読んで `send_resp` している。content-addressed なので
      `cache-control: public, max-age=31536000, immutable` を返せる
      はず。もう一歩進めて rustfs から直接 302 (presigned) にできれば
      federated peer の毎回 BEAM 叩きが消える。
- [ ] **rustfs first-boot の chown 10001 を script 化.**
      kamal `directories:` が rocky 所有で作るので container が
      書けず落ちる。今コメントで残してあるだけ。`scripts/setup.sh`
      か init container にして「初回も kamal が完結」させる。
- [x] **Follow Accept 後の backfill.** `maybe_handle_follow_accept`
      から `Federation.OutboxBackfill` を enqueue し、相手 outbox を
      **signed fetch** で辿って `public`/`unlisted` の Create を
      `notes` に取り込む。既存の follow は起動のたび
      `pending_existing/0` が拾い直す。進行状態は `/admin/backfill`。
      手で今すぐ流すなら `SukhiFedi.Release.run_script("backfill_followed_outboxes")`
- [ ] **Inbound `manuallyApprovesFollowers` の保存.**
      `RemoteAccounts.upsert_from_actor_json/1` で
      `manuallyApprovesFollowers` を読んで `:locked` に流し込む。
      カラムと `changeset_remote` の cast は今日揃えたので追加は
      parser 行 1〜2 行のみ。

## Mastodon API surface — open

- [x] **Streaming WebSocket** — `/api/v1/streaming` in the gateway (Q2 option 1).
      `user` + `public:local` live; `hashtag` / `list` / federated `public`
      wait on a `stream.new_post` producer (nothing publishes it yet).
- [ ] **Search (`/api/v2/search`)** — see [OPEN_QUESTIONS Q1](OPEN_QUESTIONS.md#q1-search-戦略--full-text-どうやるか).
- [ ] **Push delivery side.** `Addons.WebPush.send_notification/2`
      is still a stub; subscribe/get/put/delete REST is live, but
      no Notification → Push happens yet. Needs a push-web library
      + VAPID encryption. Pairs with an Oban worker that consumes
      notification rows and POSTs each subscription's
      encrypted-payload endpoint.
- [ ] **Scheduled statuses.** `/api/v1/scheduled_statuses` — no
      table yet. Same Multi+outbox pattern as `create_status`, with
      an Oban-scheduled `publish_at` worker.
- [ ] **Trends / suggestions / directory.** Optional surface;
      deprioritised.

## Misskey native API

Single addon `:misskey_api` (per [OPEN_QUESTIONS Q3](OPEN_QUESTIONS.md#q3-misskey-native-api--addon-マニフェストの粒度)).
Shares the existing contexts; only the view layer differs. The planned
endpoint surface is mapped out in [`docs/MISSKEY_API.md`](docs/MISSKEY_API.md).

- [ ] **Auth.** `/api/auth/session/{generate,userkey}` — map
      Misskey's session-key flow onto `oauth_access_tokens`.
- [ ] **`/api/i`, `/api/i/update`** — mirror Mastodon's
      verify/update_credentials in Misskey shape.
- [ ] **`/api/users/*`** — `show`, `lookup`, `notes`,
      `{followers,following,follow,unfollow}`.
- [ ] **`/api/notes/*`** — `{create,delete,show,timeline,
      local-timeline,global-timeline,hybrid-timeline,replies,
      mentions}`.
- [ ] **`/api/notes/reactions/*`** — custom emoji reactions (table
      already supports arbitrary emoji strings).
- [ ] **`/api/notes/favorites/*`, `/i/favorites`** — bookmarks
      under Misskey naming.
- [ ] **`bun/addons/misskey_api/manifest.ts`** — currently a
      placeholder shell; extend if any translators are needed
      (custom reactions, soft-renotes).

## Admin REST

- [ ] **`/api/v1/admin/*`** — accounts, reports, domain_blocks.
      `SukhiFedi.Addons.Moderation` already has the writes (suspend,
      resolve_report, block_instance). New addon
      `:admin_api` (per [OPEN_QUESTIONS Q9](OPEN_QUESTIONS.md#q9-admin-rest--admin_api-を新-addon-にするか)) so
      admin can be toggled independently from user-facing
      block/mute/report.

## Auth factors — deferred (2026-06-12 メール認証 + アプリ2FA + パスキー)

- [ ] **OCI Email Delivery の本番配線.** コードは SMTP_HOST /
      SMTP_PORT / SMTP_USERNAME / SMTP_PASSWORD / MAIL_FROM を読む
      だけの状態。OCI 側で approved sender + SMTP credentials を
      発行し、`config/deploy.yml` の gateway env.secret に足す。
      SPF/DKIM は OCI コンソール側の作業。未設定の間は log
      transport に落ちて、メールは届かない(ログには出る)。
- [ ] **パスキーの実機スモーク.** 検証は wax + 合成クレデンシャルの
      テストまで。デプロイ後に iOS/Android/YubiKey の実機で
      register → usernameless login を一往復しておく。
- [ ] **TOTP リカバリコード.** TOTP を失った人の道は今のところ
      「メールコードでログイン」(事実上の回復経路) か admin eval。
      バックアップコード 10 枚方式を足すなら hashed-codes カラム
      1 本 + 表示 UI。
- [ ] **メール変更時の旧アドレスへの通知.** 乗っ取り検知の定石。
      Mailer はあるので、confirm_verification の成功後に一通
      送るだけ。
- [ ] **ログイン時の suspension チェック.** password 経路が元々
      見ていないのに合わせて email/passkey 経路も見ていない
      (parity)。API 側の gate 任せでよいか、入口で締めるか決める。
- [ ] **webauthn_challenges の掃除.** 今は take_challenge の
      ついで掃除のみ(在庫は「進行中の儀式」分だけのはず)。
      気になる量になったら Oban cron へ。

## Operational / hardening

- [ ] **Presigned-URL media uploads (>8 MiB).** Inline POST caps at
      the distributed Erlang transport limit. Surface
      `SukhiFedi.Addons.Media.generate_upload_url/3` over a new
      capability that returns `{upload_url, fields}`. Design in
      [OPEN_QUESTIONS Q5](OPEN_QUESTIONS.md#q5-メディア-8-mib--presigned-url-の-capability-形).

- [ ] **`custom_emojis` のローカル絵文字に一意制約が効いていない.**
      `unique_index(:custom_emojis, [:shortcode, :domain])` は、`domain` が
      NULL (= ローカル) の行どうしを「別物」として扱うので、同じ shortcode が
      何度でも入る。`CustomEmojis` は upsert をコードで補った (ローカルは
      shortcode で探して更新) が、DB は何も言わないまま。既存の重複行を
      どう寄せるか (どの行を残すか) を決めてから、`shortcode WHERE domain IS
      NULL` の部分一意インデックスを足す。`scripts/prepare_volpeon.mjs` の
      `ON CONFLICT (shortcode, domain)` も同じ理由で再実行のたびに重複する
      (新しい `scripts/emoji_import.jl` + `POST /api/admin/emojis` が置き換え)。
- [ ] **`scripts/env_audit.jl` を CI で回す.** 文書に無い変数は 0 件にした
      (docs/ENV.md)。`ENV_AUDIT_STRICT=1` で増えたら落とせるが、CI の
      イメージに tsbvm / tsubakic が無い。入れるか、`make` の手元用ターゲットに
      するか決める。
- [ ] **絵文字インポートを本物のサーバーで一度通す.** `host` は tsbvm に
      入った (nyanrus/tsubaki #7、merge 済み)。`scripts/emoji_import.jl` は、パック / Misskey サーバー / JSON
      ファイルの 3 つの入口を持ち、本物のファイルと HTTP、契約どおりに答える
      偽サーバーまでは通した。本物の `POST /api/admin/emojis` と本物の Misskey
      に対しては未実行 (`EMOJI_DRY_RUN=1` から)。通ったら
      `scripts/prepare_volpeon.mjs` と、`Makefile` のコメントの古い手順を消す。
      (`mix sukhi.emoji.import` と `CustomEmojis.import_from_*` は、もう無い。
      zip は `unzip` してパックとして読む。以前の zip 取り込みは、画像を
      `data:` URL にして `image_url` (varchar(255)) に入れていたので、
      そもそも入らなかった。)

### レート制限の見え方と単位 (2026-10-25 の CPU 絞り試験から)

`SukhiFedi.Web.RateLimitPlug` の全体制限 (IP ごと・60 秒に 500 回) は、
試験の負荷 (`ab` 同時接続 20 以上) で簡単に当たり、同じ回線の人の画面にも
素の JSON `{"error":"rate_limited"}` がそのまま出た。守る側としては
働いていた (app は落ちず、他の IP の応答は 200 のまま) ので、直すのは
「当たったときの見え方」と「数える単位」。順に。

- [ ] **レート制限に当たっても、最低限 Web が読み込まれるようにする.**
      今は `skip_prefixes` が `/static/` `/_app/` `/twemoji/` だけなので、
      SPA の HTML 本体は数えられ、当たると 429 の JSON が画面に出て、
      何も読み込めない。HTML のシェルと、画面を出すのに要る最小の
      ファイルは 429 にしないようにする (数えないか、別の枠にする)。
      API だけを止めれば、守る目的は変わらない。
- [ ] **そのうえで、「レート制限にかかっている」と画面で分かるようにする.**
      シェルが出たあと、API が 429 を返したら、素の JSON ではなく
      「いま混み合っています、○秒後にもう一度」のような案内を出す。
      Web 側は今、ログイン・投稿・フィードバック・メール確認など個別の
      画面でだけ 429 を扱っていて (`Composer.svelte` `login/+page.svelte`
      など)、全体で受ける所が無い (`web/src/lib/api.ts` に集めるのが
      自然)。本文にも `retry_after` を入れる (今はヘッダの `retry-after`
      だけで、`RateLimitPlug` の JSON 本文には無い。`api/` の
      `TokenRateLimit` 側は本文に入れている)。
- [ ] **ログイン済みで、アカウント作成から 1 か月たった人には、アカウント別の制限を当てる.**
      IP ごとだと、同じ回線 (家庭の NAT、モバイルの CGNAT、学校) の人が
      同じ枠を分け合い、一人の負荷に巻き込まれる。作成から 1 か月たった
      ログイン済みアカウントは、IP ではなくアカウント ID で数える。
      新しいアカウントと未ログインは、今までどおり IP で数える
      (使い捨てアカウントで枠を増やされないための 1 か月)。
      決めること: ① `RateLimitPlug` はルーティングの前にあって、誰かを
      まだ知らない。セッション / トークンの検索を前に出すか、認証のあとに
      数え直すか。② 数は同じ 500/分でよいか。③ 作成時刻は
      `accounts.created_at`。④ `api/` の `TokenRateLimit`
      (トークンごと・5 分に 300 回) と二重にならないか。

### 0.5 OCPU の負荷試験 (2026-10-25) と、そこから出た改善点

本番の箱 (Arm A1 2 OCPU) で、sukhi の CPU 上限を元の比率のまま合計
0.5 に絞った (app 0.23 / postgres 0.12 / rustfs 0.06 / nats 0.06 /
anubis 0.03)。`docker update --cpus` で 30 分、UI にお知らせを出して実施。
箱の中から、別 IP (`cf-connecting-ip` を変えた 203.0.113.x) の仮想ユーザー
が、公開タイムライン・`/api/v1/instance`・nodeinfo を約 1 秒に 1 回の
頻度で読む形 (書き込みなし。Cloudflare と anubis は通らない。負荷発生器は
同じ箱で動いた)。

| 同時ユーザー | 成功 | 503 | 応答 中央値 / 遅い側 5% | 処理量 |
|---|---|---|---|---|
| 10 | 100% | 0 | 0.03 / 0.64 秒 | 9 req/s |
| 50 | 57% | 43% | 0.29 / 4.8 秒 | 22 req/s |
| 100 | 64% | 36% | 2.0 / 5.7 秒 | 29 req/s |

0.5 OCPU で余裕があるのは約 10 人まで。落ちはせず、負荷を止めるとすぐ
戻った。デッドロックの形は見つからなかった (ソースと、本番の
`pg_stat_database.deadlocks` = 0)。app と postgres の両方が CPU 上限に当たっていた
(105 秒で抑制回数が app +917 / postgres +734)。

- [ ] **接続プールが詰まったとき、500 ではなく 503 + `Retry-After` を返す.**
      50 人の段階で、app のログに
      `DBConnection.ConnectionError ... dropped from queue after 105ms`
      が出て、そのまま 500 になった (プール 10 本)。「混みすぎ」を
      「バグ」に見せている。`DBConnection.ConnectionError` の
      queue 切れを入口の plug で受けて、503 と `retry-after` に直す。
      上の「画面で分かるようにする」案内とつなげやすくなる。
- [ ] **api ノードへの RPC が 5 秒待ってから失敗する (遅く失敗する).**
      失敗した要求の応答時間が 5 秒前後に固まっていた。`web/plugin_plug.ex` の
      `:rpc.call` が 5 秒のタイムアウトに毎回ぶつかっていると見ている
      (503 は `GatewayRpc.unavailable_body`。この対応は、まだ確かめていない)。
      待っているあいだ、リクエストのプロセスを握り続けるので、混んだときに
      自分で自分を重くする。同時に走らせる RPC の数に上限を付けて、
      溢れた分はすぐ 503 にする (早く断る)。`:rpc.call` は 5 秒で
      切れても、相手の処理は走り続ける点も合わせて見る。
- [ ] **CPU の割り振りを、固定の上限 (`cpus`) から重み (`cpu.weight`) へ.**
      今の上限は合計 4.3 (箱は 2 CPU)。空いていても超えさせないので、
      `rustfs` は上限 0.5 に 10 万回以上当たり、`postgres` も当たっていた
      (そのとき箱の CPU は 2 割台)。重み (`docker update --cpu-shares`、
      今は全員 100) なら、混んだときだけ比率で分け、空いていれば誰でも
      使える。例: postgres 400 / app 300 / rustfs 100 / nats 100 /
      anubis 100。総枠を絞りたいときは、親の cgroup に上限を 1 つ付けて
      (`--cgroup-parent`) 子は重みで分ける。同じ 100 人試験で、上限と重みを
      比べてから決める。デプロイ設定 (haloy) のどこに書くかは、まだ見ていない。
      自作のコントローラーは、重みで足りないと分かってから。

試験のあとに、もう一つ分かったこと: 絞ったまま (postgres 0.12) だと、
ログインして読む `timelines/home` が、負荷が終わったあとも 503
(`plugin_rpc_failed`、gateway のログは `badrpc :timeout`) のままだった。
公開タイムラインは同じ時間に 200 (約 1 秒)。上限を元に戻した直後に読める
ようになったので、CPU 起因は確か (home の取得が 5 秒の RPC に間に合わない、
という細部は推定)。0.5 OCPU の箱で動かすなら、home の取得 (フォロー先の
結合) の重さを計って、下のキャッシュと合わせて軽くする必要がある。

### 「遅くても、つながって使える」ための仕組み

混んだときに、500 や空の画面ではなく、遅くても読める形に落ちる。
効きそうな順に 4 層。数値 (同時処理の上限、待ち行列の長さ、キャッシュの
秒数) は、勘で決めずに、上の 100 人試験で変えて比べて決める。

- [ ] **1. 同じ答えを使い回す (短いキャッシュ).** 試験の要求の 5/8 は
      公開タイムラインで、中身は誰が見ても同じ。1〜2 秒、プロセス内で
      共有すれば、DB への問い合わせは「100 人でも 1 秒に 1 回」になる。
      ログインしたユーザー別の画面 (home など) は別に考える。数秒
      古くなるのと引き換え。
- [ ] **2. 入口で同時処理数を絞り、溢れたらすぐ 503 + `Retry-After`.**
      同時に処理する数に上限を付け、短い待ち行列に入れ、それも溢れたら
      すぐ断る。今は、接続プール枯渇は 500、RPC 詰まりは 5 秒待ってから
      503 で、断るのが遅い。早く断れば、受けた分の応答が速くなる。
- [ ] **3. 重いものから先に諦める (優先度).** カウント・おすすめ・
      プレビューなどは後回しにするか、古いものを返す。投稿・ログイン・
      自分の home は最後まで通す。
- [ ] **4. クライアントも慌てない.** 503 + `Retry-After` を受けたら、
      間隔を空けて (ランダムなゆらぎ付きで) 再試行し、「いま混んでいます」
      と出す。下の 2 項目につながる。

- [ ] **Web: 「混んでいるだけ」の失敗を、待ち表示にして、見えていた一覧を残す.**
      画面の「잘 닿지 않았어요. 다시 한번 해볼까요?」は、WebTransport では
      なく、タイムラインを読む通常の API 取得の失敗 (`timeline/+page.svelte`
      の `error = $t('common.deliverFailedRetry')`)。原因は 2 つ:
      ① `isConnectivityError` (`web/src/lib/connection.ts`) は、本文のない
      5xx と `gateway_not_connected` だけを「つながるのを待つ」扱い
      (静かな待ち表示 + 自動で読み直し) にするが、`api.ts` はサーバーの
      JSON の `error` をそのままメッセージにするので、`gateway_rpc_failed`
      (RPC タイムアウトの 503) や `rate_limited` (429) はリストに入らず、
      エラー文に落ちる。メッセージの文字列ではなく、ステータス
      (429 / 502 / 503 / 504) と `Retry-After` で判定する。② `load(reset)`
      は、読む前に `items = []` で一覧を空にするので、失敗すると、空の画面に
      エラー文だけが残る。失敗しても見えていた一覧は消さず、上に「混んで
      いて、最新でないかもしれません」と出し、初回で何も無いときだけ待ち
      表示にする。
- [ ] **WebTransport (karutte, `webtransport.f3liz.casa`) の再接続を、詰まりに強くする.**
      今は、失敗したら黙って 1 秒 → 30 秒まで倍々で再接続する
      (`web/src/lib/webtransport.ts`)。弱点は 3 つ: ① 再接続のたびに
      `/api/wt` (gateway、認証で DB も使う) でチケットを取り直す。チケットの
      期限は 5 分 (`wt_ticket.ex`) なので、期限内は使い回して、gateway を
      叩く回数を減らす。② ゆらぎ (ジッター) が無く、全員が同じ周期で動く
      ので、復旧の瞬間に一斉に戻ってくる。③ 失敗の理由 (WT エッジが重い /
      gateway が重い / チケット切れ) を区別していない。`Retry-After` があれば
      従い、タブが裏にあるときは間隔を延ばす。WT は gateway と別ノードなので、
      gateway が詰まっていても、すでに繋がったセッションは動き続ける。
      タイムラインのライブ更新は WT だけで、SSE (`notify.ts`) は通知用なので、
      WT が使えないとき、更新は黙って止まる。代わりの経路を階段にする:
      WebTransport → WebSocket (gateway の `/api/v1/streaming`、すでにある)
      → ゆっくりした取得 (`since_id` で 30〜60 秒おき、ジッター付き)
      → 手動の「更新」ボタンと「混んでいます」の案内。WS は gateway に乗る
      ので、gateway が詰まっているときは、早めに下の段へ降りる。

## Federation / signing — hackers.pub 401 から派生

`bun/handlers/sign_delivery.ts` で署名した POST が hackers.pub
(Fedify 2.x ベース) で `"Failed to verify the request signature."`
を返し続ける問題から。bun 内の自己 verify は `ok: true`、JWK n と
PEM modulus も bit-identical。手前のヘッダ最小化 (v0.1.72) も効かず。
こちら側の rendering / signing の幅を広げて、相互運用性を上げて
いく。軽い順に並べる。

- [ ] **Update Person で actor 更新通知を撒く.** 既知のフォロワー
      inbox 全部に `Update {actor}` を送って、相手側の actor cache を
      強制的に invalidate させる。我々の鍵そのものは変えない (ので
      他の peer への副作用は最小)。
      実装場所: `SukhiFedi.Accounts.update_credentials/2` の最後に
      sns.outbox.actor.updated を outbox に投入する経路がもう一部
      ある。`Federation.Outbound` から既存 followers 一覧に
      fan-out するワーカを足すだけ。fedify 側に `update.actor` の
      translate ハンドラが要る。

- [ ] **HTTP Signature: RFC 9421 単発投げ.** いまは
      `spec: "draft-cavage-http-signatures-12"` 固定。`spec: "rfc9421"`
      でも投げてみるオプションを `SignDeliveryPayload.algorithm` で
      足してあるが、ゲートウェイ側が `cavage` 固定で渡している。
      `Federation.Outbound` で `algorithm: "rfc9421"` を一度試す
      A/B フラグを足して、hackers.pub だけ rfc9421 で投げる実験。

- [ ] **Double-knocking 実装.** RFC 9421 で先に投げ、`400`/`401` が
      返ったら同じ Request を cavage で再送。通った spec を inbox の
      origin ごとに ETS で覚える。fedify の `fetch` 側 (`handlers/
      fetch.ts`) は既にこの戦略でやっているので、`handlers/
      sign_delivery.ts` 側にも同じ shape の specMemory を持たせる。
      Elixir 側からは `algorithm` を渡さず、bun が判定する形に。

- [ ] **Object Integrity Proofs (FEP-8b32) 出力.** Activity 自体に
      `proof: {type: "DataIntegrityProof", cryptosuite:
      "eddsa-jcs-2022", verificationMethod, proofValue}` を埋め込む。
      これがあれば HTTP Signature が通らなくても peer 側で
      Activity 自体の真正性を確認できる ─ Misskey/Sharkey 系は
      これを優先することがある。fedify は `signObject` を持って
      いるのでハンドラを足せば実装は短い。鍵は Ed25519 を別立てで
      生成する必要がある (RSA とは別系統)。
      ─ 影響範囲が大きいので、Update Person と RFC 9421 が
      ダメだった時の最後の手段。

- [ ] **ojak の LD署名 (RsaSignature2017) を、Mastodon 以外にも親切な形にする.**
      `OJAK_LD_BACKEND=ojak` で出す署名ブロックは Mastodon の形 (options に
      `expires` も署名対象で入り、埋め込み `@context` が無い)。ojak は完全な
      Mastodon 互換を要するサーバーで使われている実装なので、これは意図どおり。
      一方 sukhi の native は fedify の形 (creator + created + `@context`) で、
      native の `LdSignature.verify` は ojak の形を検証できない
      (`test/sukhi_fedi/fedi/ojak_test.exs` に記録)。Misskey / fedify 系が
      ojak の形を受け入れるかは実サーバーで未確認。
      やること: (1) 実サーバーで受信を確認する。(2) 受け入れられない相手が
      あるなら、ojak に「fedify 形で出す」オプションを提案する (upstream は
      `sukhi-social/ojak-ex`)。(3) native の verify も `expires` と埋め込み
      `@context` を読めるようにして、どちらの形でも検証できるようにする。
      それまでは `:native` を既定のままにする。

- [ ] **fedify v2 への上げ.** いまは `@fedify/fedify@1.10.8`。
      Fedify 2.x は signing/verify の defaults と internal API を
      変えていて、hackers.pub などピアと同じバージョン世代になれば
      相互運用が安定する可能性がある。Breaking change を含む:
      - `signRequest` / `verifyRequest` のオプション形
      - `getAuthenticatedDocumentLoader` の `identity` 引数まわり
      - `Federation` クラスの構築方法と context loader
      - `KvStore` / `KeyCache` インターフェース
      手順:
        1. `bun/package.json` の `@fedify/fedify` を `^2` に上げて
           `bun install` → 型エラー全部洗い出す
        2. `bun/handlers/{sign_delivery,verify,inbox,fetch,build/*}.ts`
           を順に v2 シグネチャに合わせる
        3. `bun test` (まだ薄いので integration を足す)
        4. staging で kamal 経由 reboot → 既知 peer (Mastodon /
           Misskey / Sharkey / hackers.pub) と双方向に follow/accept
           が往復するかスモーク
        5. 通ったら本番

## Admin frontend (work in progress — paused mid-implementation)

Server-rendered HTML admin UI for the gateway. Stack chosen: **htmx +
Plug.Router + EEx** (not Phoenix LiveView — Phoenix/Endpoint isn't in
this codebase, the infra delta would dwarf the admin code). Auth: paste
a Mastodon OAuth bearer token, server verifies via
`SukhiFedi.OAuth.verify_bearer/1`, requires `account.is_admin = true`,
session-cookie persists the bearer. Resume from "what's done" below.

### Done already in this branch (deployed to sukhi.f3liz.casa)
- Watcher routes (`/`, `/api/watchers`, `/api/nodeinfo`,
  `/api/stats/stream`) gated on `:nodeinfo_monitor` addon; Kamal env
  sets `DISABLE_ADDONS=nodeinfo_monitor`. Real-SNS deploy returns 404
  on those paths.
- Kamal `config/deploy.yml` has per-service memory + cpu options
  sized to 2 vCPU / 12 GiB.
- All moderation business logic already exists:
  `SukhiFedi.Addons.Moderation.{suspend_account/3, unsuspend_account/2,
  list_reports/2, resolve_report/2, list_instance_blocks/1,
  block_instance/4, unblock_instance/2}`.

### Open decisions (already made, recorded so resume is straight)
- Cookie session signing key: **new `SECRET_KEY_BASE` env var** (not
  reused from `ERLANG_COOKIE`). Generate `openssl rand -hex 64`.
- Bootstrap admin token: **standard Mastodon OAuth flow** — admin
  obtains a bearer via any Mastodon client / API call, then pastes
  into `/admin/login`. No redirect-bounce OAuth UI yet.
- Stack: htmx (via CDN) + Plug.Router + EEx. No Phoenix, no SPA build.

### To do, in order

1. **Env plumbing for `SECRET_KEY_BASE`.**
   - `elixir/config/runtime.exs`: read it (`fetch_env!` in prod), store
     as `config :sukhi_fedi, :secret_key_base, ...`.
   - `.env.example`, `.kamal/secrets.example`, `docs/ENV.md`: add it
     with generation command and "must be stable across deploys —
     rotating invalidates every admin session" caveat.
   - `config/deploy.yml`: add `SECRET_KEY_BASE` to gateway `env.secret`.
   - `.kamal/secrets` (gitignored, local): paste actual value.

2. **`/admin` router infra.**
   - `elixir/lib/sukhi_fedi/web/admin/render.ex`: helper around
     `EEx.eval_file/2` rooted at `priv/admin_templates/`, returns
     iodata. Layout wrapping helper.
   - `elixir/lib/sukhi_fedi/web/admin/auth_plug.ex`: reads bearer from
     session cookie, calls `verify_bearer`, requires `is_admin`. 302 to
     `/admin/login` on miss. Assigns `:admin` to conn.
   - `elixir/lib/sukhi_fedi/web/admin/router.ex`: a `use Plug.Router`.
     Pipeline: `put_secret_key_base` → `Plug.Session` (cookie store,
     `_sukhi_admin` key, signing salt) → `fetch_session` → for
     non-`/login` routes also `AuthPlug`.
   - `elixir/lib/sukhi_fedi/web/router.ex`: `forward "/admin", to:
     SukhiFedi.Web.Admin.Router`.

3. **Login + dashboard pages.**
   - `priv/admin_templates/_layout.html.eex`: shell w/ nav (Users,
     Reports, Federation), htmx via `https://unpkg.com/htmx.org@2`.
     Minimal inline CSS or single small stylesheet — admin tool, not
     marketing.
   - `priv/admin_templates/login.html.eex`: paste-token form (POST
     `/admin/login`).
   - Controller in `admin/router.ex` for `POST /admin/login`: take
     `token`, run `verify_bearer`, require `is_admin`, store the raw
     token in session, redirect to `/admin`. `DELETE /admin/logout`
     clears session.
   - `priv/admin_templates/dashboard.html.eex`: counts (users,
     pending reports, instance blocks), recent activity.

4. **Users page.**
   - `users_controller.ex`: list (paginated), search by username/domain,
     `POST /admin/users/:id/suspend` / `unsuspend` returns the table
     row fragment (htmx swap-target).
   - Templates: `users/index.html.eex`, `users/_row.html.eex`.

5. **Reports queue.**
   - `reports_controller.ex`: list by status (open/resolved), resolve
     button hits `POST /admin/reports/:id/resolve` → row fragment swap.
   - Templates: `reports/index.html.eex`, `reports/_row.html.eex`.

6. **Domain (instance) blocks.**
   - `instance_blocks_controller.ex`: list, add (form), remove.
     Severity = silence | suspend.
   - Templates: `instance_blocks/index.html.eex`, `instance_blocks/_form.html.eex`.

### Deferred to a follow-up PR
- **Instance settings page.** Requires new `instance_settings` table
  (single-row k/v) since `INSTANCE_TITLE` is env-only today. Migration
  + Cachex layer + the admin form.
- **Automated OAuth bounce login** (`/admin/login` redirects to
  `/oauth/authorize`, callback exchanges code). Currently admin pastes
  a token. Fine for v1.
- **Audit log.** `who-did-what-when` for admin actions. Out of scope
  initially; revisit when there's more than one admin.

### Schemas to lean on (no migrations needed for steps 1–6)
- `accounts`: `is_admin`, `suspended_at`, `suspended_by_id`,
  `suspension_reason`, `domain`. Local users = `domain IS NULL`.
- `reports`: `account_id`, `target_id`, `note_id`, `comment`, `status`,
  `resolved_at`, `resolved_by_id`.
- `instance_blocks`: `domain`, `severity`, `reason`, `created_by_id`.
- `oauth_access_tokens`: lookup via `SukhiFedi.OAuth.verify_bearer/1`.

### Resume command
```
# In a fresh session, point Claude at the admin TODO and start step 1:
git status
# Then ask: "TODO.md の Admin frontend のステップ 1 から実装再開"
```

## Native seams — follow-ups (docs/native-seams.md)
- [ ] 不正な UTF-8 を `HTML.sanitize/1` / `Linkify` に渡すと raise する(分離前から)。NIF を入れる前に、facade の境界で 1 回だけ scrub するか決める。
- [ ] OpenGraph の regex が呼び出しごとに実行時コンパイルされる(性能のみ)。NIF にする前に module attribute へ。
- [ ] sanitizer は 1 回で収束しない入力がある(20,000 件中 49)。保存前に 1 回で十分かを確かめる。

## 構造の見直し候補 (2026-10 の調査から。計測はしていない)
小さい順。詳しい根拠はセッションの調査メモ(コードの読み取りのみ)。
- [x] **gateway が自分自身に NATS で往復している** (`fedify.*.v1`)。`Fedi.Service`
      は gateway 内にあるので、`Fedi.Verifier/Inbox/Fetcher` を直接呼べば足りる。
      → `Fedi.Service.call/2` を足し、gateway の `FedifyClient` はそれを呼ぶだけに
      (JSON の往復は残してあるので、戻り値の形は変わらない)。delivery の
      `FedifyClient`(translate / sign)は別ノードなので NATS のまま ── 複製の解消は
      下の「delivery に UrlGuard / ActorJson / schema の複製」と同じ話。
- [ ] **api↔gateway の `:rpc` 157 呼び出しが型なし.** `{:ok, {:ok, _}}` の二重ラップが
      実バグになった実績あり。`gateway_not_connected` の分岐が 66 か所。型付き
      クライアントに集約する。
      **済み (2026-10-15):** `GatewayRpc.run/4`(`{:ok, x} | {:error, e} |
      {:unavailable, why}` に平らにする)と `unavailable_body/1`(503 の本文)を足し、
      `capabilities/*`・`status_hydration`・`token_cache`・`router` の約 158 か所を
      ぜんぶ移した。`GatewayRpc.call` を直接呼ぶ所は無い(テストの差し替え口として
      `call/4` は残す)。`TokenCache.verify/session` も同じ形で返す ── 二重ラップを
      合わせるための注意書きが要らなくなった。移す途中で、`{:error, e} -> {:error, e}`
      と素通ししていた補助関数が `CaseClauseError` になる所が一つあった
      (`account_by_id`)。コンパイラは網羅していない `case` を警告しないので、
      これからも `run/4` の結果を受ける `case` には `{:unavailable, _}` を忘れずに。
      のこり: 各 capability に残る小さな `rpc_error/1`(`ok/2` を使うので、ファイル
      ごとに一行)。
- [ ] **秘密鍵 JWK を JSON にして NATS に流し、配送ごとに DB + 署名往復**
      (`delivery/worker.ex`)。署名を delivery に同居させる案。
- [x] **秘密フィールド入りの Ecto `Account` が RPC 戻り値と ETS (`TokenCache`) に載る.**
      公開投影に絞る。
      → api の RPC が通る扉を gateway に一つ置いた(`SukhiFedi.RpcGate.call/3`)。結果の
      中の秘密フィールド(`private_key_jwk` / `ed25519_private_key_jwk` /
      `password_hash` / `totp_secret` / `totp_last_used_step`)を、Ecto スキーマの構造体
      とマップのどこにあっても `nil` にして返す。`Account` だけでなく `Deco` の鍵も、
      `verify_bearer` の `{:ok, %{account: …}}` も、`SessionCookie.resolve_all` が返す
      セッションの中のアカウントも、一か所で。api の `GatewayRpc` は扉を通り、扉の
      まだ無い古い gateway には従来どおり直接呼ぶ(ローリングデプロイ用)。
      api は秘密フィールドを一つも読んでいない(確かめた)。`email` は触っていない。
      別ノード(名前付き gateway ノードに、別の BEAM から分散 Erlang で)でも確かめた:
      扉を通した `verify_bearer` は秘密 4 つが `nil`、`is_admin` は残る。扉を通さない
      直接呼びで秘密が入っていることの対比は、その実行では出力が切れて見ていない。
      **まだ**: 本番の構成(api と gateway が別のコンテナ)での確認。
- [~] **delivery に UrlGuard / ActorJson / schema の複製** (CODE_STYLE §3 に反する)。
      **UrlGuard は一つにした (2026-10-15):** `shared/`(`:sukhi_shared`)の
      `SukhiShared.UrlGuard`。elixir/・delivery/・combined/ が path 依存で引く。複製の
      二つのファイルと二つのテスト表は無くなった。delivery の Docker のビルド文脈を
      ルートにした(`release.yml`・`delivery/Dockerfile`・compose の例)。
      **Docker で確かめたこと:** `delivery` イメージはルート文脈で最後までビルドが通った。
      `gateway` / `combined` は `COPY shared` と `mix deps.get`(path 依存の解決)までは
      通るが、そのあと `ojak`(Rust の NIF)で止まる ── 変更前の `origin/main` でも
      同じ場所で止まる(Apple Silicon の aarch64 musl に、ビルド済みのライブラリが無く、
      cargo も無い)。なので、この二つのイメージの最後までのビルドは、CI の
      ランナーなどで確かめる必要がある。
      **訂正 (同日、あとで):** 「aarch64 musl にビルド済みが無い」は読み違いだった。
      配布ファイルは v0.1.1 に musl の x86_64 / aarch64 とも揃っている。本当の原因は、
      **依存を全部まとめて `mix deps.compile` するときだけ、`ojak` の取得処理が
      `:public_key` を見失う**こと(`"function :public_key.cacerts_get/0 is undefined
      (module :public_key is not available)"` を、取得の `rescue` が飲み込み、cargo に
      回って止まる)。arm64 の素のコンテナでも再現し、`ojak` だけを
      `mix deps.compile ojak` すると取れる。`extra_applications` に
      `:inets, :ssl, :public_key` を足すだけでは直らなかった。`ojak` が入ったのは
      2026-10-14(`1cdad78`)で、release ワークフローの最後の成功はその前(2026-06-06)
      なので、**次のリリースのビルドも同じところで止まる見込み**。直す場所は
      ojak-ex 側(取得の前に OTP アプリのパスを確保する、など)。**イシュー: [sukhi-social/ojak-ex#1](https://github.com/sukhi-social/ojak-ex/issues/1)(2026-10-15)。**
      **直った (2026-10-15):** ojak-ex の main(`a93153e`)で直り、`v0.1.2` を出した。
      sukhi-fedi は `v0.1.2` に上げ(`elixir/mix.exs`・両方の `mix.lock`)、`gateway` と
      `combined` のイメージが、ルート文脈で最後までビルドできた(aarch64 musl、
      `using the prebuilt library … v0.1.2`)。**CI のランナー(amd64)での確認は未**。
      **ActorJson も一つにした (2026-10-15):** 本体は `SukhiShared.ActorJson`
      (domain を引数で受け、account は欄を読むだけなので、どちらの `Account` でも通る)。
      `SukhiFedi.AP.ActorJson` / `SukhiDelivery.AP.ActorJson` は、自分の
      `Config.domain!()` を渡すだけの細い窓口で、呼び出し側(約30か所)はそのまま。
      「もう一方も同じ commit で直すこと」の注意書きは要らなくなった。
      **schema は一つにしていない(わざと):** delivery の schema は gateway の
      ものを「読むだけ」に切り詰めた写し(changeset・関連・使わない欄が無い)で、
      delivery が書かない表を書けないようにする役目もある。`Account` だけ 288 行の
      差があるのは、そのため。複製というより細い投影なので、このまま。
      以下は、UrlGuard の前の記録。
      **わかったこと (2026-10-15):** 複製はもう、実害のある形でずれていた。
      gateway の `UrlGuard` は 2026-09-22 に `192.0.0.0/16` 全体を弾くのをやめた
      (`192.0.64.0/18` は Automattic の普通の公開空間)が、delivery の複製は
      `a == 192 and b == 0` のまま残り、その帯の相手への配送を断っていた
      ── 直した。delivery の `UrlGuard` にはテストも無かったので、gateway と
      **同じ表**のテストを足した(旧い一行に戻すと落ちることを確かめた)。両方の
      `UrlGuardTest` と `url_guard.ex` に「もう一方も直すこと」と書いてある。
      `ActorJson` は URI の組み立てが inline なだけで、出力の形は同じ。
      **のこり(判断が要る):** 本当に一つにするなら、共有の path 依存
      (`shared/` のような app)を elixir/ と delivery/ の両方から引く形。ただ、
      `release.yml` の delivery イメージはビルド文脈が `./delivery` だけなので、
      文脈を広げるか、依存を vendoring する必要がある。Docker のビルドを確かめられる
      ときに。
- [~] **`Release` の一度きり関数 (pre-v0.1.22 向けなど) → スクリプトへ。**
      **済み (2026-10-15):** 消さずに、`elixir/priv/scripts/*.exs` へ移した(6 つ:
      `publish_initial_notes_for_backfill` / `resync_default_watcher_summary` /
      `delete_all_watcher_notes` / `broadcast_actor_update` /
      `backfill_monitored_instances` / `backfill_followed_outboxes`)。流し方は
      `bin/sukhi_fedi eval 'SukhiFedi.Release.run_script("名前", [引数])'`(引数は
      スクリプトの中で `args`)。`Release` に残るのは、`migrate_all` /
      `check_migration_sanity` / `seed_*` / `create_admin` / `run_script` / `scripts`。
      **のこり:** `Maintenance` の `rebuild_remote_note_ids` / `wipe_remote` は
      SQL で足りる、という見立て(未着手)。
- [ ] **管理画面の EEx 約 1800 行 → SPA の `/admin` へ** (`/api/admin/*` の JSON API は既にある)。
      下の Admin frontend (htmx) 計画の見直しと同じ話。
