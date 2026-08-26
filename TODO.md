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
- [ ] **`SukhiFedi.Addons.Media` の compile-time `@bucket` / `@endpoint`.**
      `lib/sukhi_fedi/addons/media.ex:36-41` で `System.get_env` を
      モジュール属性で読んでいる。release build 時に焼き込まれて
      runtime で効かない。今は presigned upload 経路でしか使って
      いないので無害だが、信じて触ると踏む地雷。`Application.get_env`
      に揃える。
- [ ] **rustfs first-boot の chown 10001 を script 化.**
      kamal `directories:` が rocky 所有で作るので container が
      書けず落ちる。今コメントで残してあるだけ。`scripts/setup.sh`
      か init container にして「初回も kamal が完結」させる。
- [ ] **Follow Accept 後の backfill.** `maybe_handle_follow_accept`
      は相手 outbox を fetch しない (Mastodon 標準ではある)。
      UX として「フォローしたのに静か」が痒い。意図的後回し。
      ([memory: sukhi-fedi-follow-backfill](../.claude/projects/-Users-nyanrus--shiro/memory/sukhi-fedi-follow-backfill.md))
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

- [ ] **診断ログを剥がす.** v0.1.69〜v0.1.73 で足した:
      - `bun/handlers/sign_delivery.ts` の `sign.done` 全 header
        出力と `sign.selftest` 自己 verify
      - `bun/handlers/fetch.ts` の `fetch.failed` JSON 出力
      - `delivery/lib/sukhi_delivery/delivery/worker.ex` の
        `delivery POST ...` 全 header 出力と `delivery 4xx from`
        body 残し
      Federation 周りが落ち着いたら sign.done と delivery POST の
      フル出力は外す。sign.selftest と非 2xx の body は残してよさそう。

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
