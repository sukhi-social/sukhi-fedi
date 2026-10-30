# Anubis — bot よけの置き場所と効かせ方

[Anubis](https://github.com/TecharoHQ/anubis) を sukhi-fedi の前に置いて、
特定の HTML ナビゲーションだけに proof-of-work challenge を出させる。
Fediverse 連携 (`/inbox`, `/users/*`, `/.well-known/*`) と SPA の API 通信
(`/api/*`, `/oauth/*`) は素通し ─ ここを止めると federation か signup が
壊れる。

## 効かせる対象

ログインも加入も、ひとつの「通り道」`/check` を経由する。Anubis は
`/check` だけを CHALLENGE する。

| path | 扱い | 理由 |
|---|---|---|
| `/check` (GET) | CHALLENGE | 唯一の PoW ゲート |
| `/login` (GET/POST), `/signup` (GET), `/logout` | ALLOW | フォーム表示は止めない |
| `/api/v1/*`, `/oauth/*` | ALLOW | SPA fetch は JS challenge を解けない |
| `/inbox`, `/users/*`, `/.well-known/*`, `/nodeinfo/*` | ALLOW | 止めると federation 死ぬ |
| `/static/*`, `/uploads/*` | ALLOW | 画像・JS・CSS |
| `/up`, `/metrics` | ALLOW | health check |

## `/check` の通り方

`/check` は SPA shell を返すだけの HTML エンドポイント。`?intent=` で
出口が変わる。Anubis cookie はドメイン全体に効くので、一度通れば
当面は他の `/check` 訪問もすぐ抜ける(つまり「ログインのたびに
PoW」ではなく「久しぶりに来た人は一度だけ」)。

> **web-next(Node の郵便局)でも同じ関所を通る。** SPA ではブラウザが `/check` で手順を進めたが、
> web-next では `/check` がサーバの手順の一部になる ── 一段目のあとで `/check?intent=login|signup`
> へ redirect し、anubis が PoW を終えて届いたところで、OAuth を始める・アカウントを作る。
> 行き先は session に置く一度きりで、URL の `intent` は合図にすぎない(`web-next/server/routes/auth.ts`)。
> メールの 6 桁コードを送るのも `/check` の後(`login-email` と、加入の最初の段)── 「メールは Anubis の後」。

### login
```
1. ユーザが「入る」を押す
   ↓
2. /login                    ← server-rendered, PoW なし
   ↓ 名前と合言葉を入れて submit
3. session_token cookie が立つ → /check?intent=login へ redirect
   ↓
4. /check                    ← ここで初めて Anubis が CHALLENGE
   ↓ PoW 解けた
5. SPA が /oauth/authorize?... を発射 → consent
   ↓
6. /app/callback?code=... → トークン取得 → /timeline
```

ログインの form 表示は素通し、submit のあとに Anubis ─ signup と
同じ「フォームの先にゲート」の姿勢。何もしていないうちに確認を
要求しない。

### signup
```
1. /signup でフォーム入力
   ↓ submit
2. SPA が下書きを sessionStorage に保存
   ↓
3. /check?intent=signup       ← Anubis が CHALLENGE
   ↓ PoW 解けた
4. SPA が下書きを読んで POST /api/v1/accounts
   ↓ 成功
5. sessionStorage クリア → /timeline
```

**signup の認可は /check を通れたときに初めて起こる**。PoW に失敗
した人のアカウントは作られない。下書きは sessionStorage に残るので、
「もう一度」で再入力なしに試せる。

## なぜ提出のとき(ページ表示時ではなく)か

- bot がやるのは「POST を 1000 回」であって「GET /signup を 1000 回」では
  ない。ページ表示時にゲートしても PoW cookie を一回取ったあと連投で
  抜けられる。
- 読みに来ただけの人を最初から待たせない。「招待コードを持ってない人」
  「迷い込んだ人」に「確かめています」を見せるのは、しずかな入り口の
  姿勢に合わない。
- 「作る」「入る」を押した直後の待ちは、人が受け入れやすい瞬間。

## なぜ共通の通り道(各ページ別ではなく)か

- Anubis の matcher が一行で済む ─ 守る面の認知負荷が下がる
- ログインと加入が「同じ確かめ方」になる ─ 対称
- 後で hCaptcha や別の方式に切り替えたくなったらこのページだけ
  書き換えれば済む
- signup の Anubis 通過 = login での Anubis 通過、を同じ cookie で
  兼ねられる(互換性チェックも自然にできる)

## デプロイ

docker-compose で gateway の前に置く。`config/anubis/botPolicies.yaml`
で matcher を上の表どおりに設定。

```
# 一度だけ生成して .env に書く ─ コンテナを再起動しても cookie が
# 失効しないように。
openssl rand -hex 32
# → ANUBIS_ED25519_KEY=... を .env へ
```

そのあと `docker compose up -d anubis` でゲートが立つ。edge (Coolify,
nginx, host) から gateway:4000 へ向いていた経路を anubis:8080 に
向け直す。

### 開発時に外す

dev では `docker-compose.override.yml` で anubis サービスに
`profiles: [disabled]` をつけて起動から外せる。あるいは直接 `:4000`
を叩けば素通し。

## 切り替え

`/api/v1/instance` の `registrations` を `true` にして招待制を外す日が
来たら、policy.yaml の matcher に `/signup` と `/signup/confirm` を
足す。policy はホットリロードできるので gateway の再起動は不要。
