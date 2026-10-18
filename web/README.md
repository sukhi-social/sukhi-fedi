# sukhi-fedi web

しずかな入り口。SvelteKit SSG SPA。atfedi.de と同じトークンで作っている。

## 動かす

```
make dev-web       # http://localhost:5173 — gateway は :4000 に居る前提
```

gateway 側は repo ルートで `make dev`（Docker 要らず）。node は `mise.toml`
が持っているので、`npm` を自分で入れる必要はない。

dev server は `/api`, `/oauth`, `/login`, `/.well-known` を `http://localhost:4000`
（Elixir gateway）に proxy する。gateway 側の起動は repo のルート README を参照。

### gateway なしで、入った状態を見る

```
pnpm run dev:mock      # http://localhost:5173 — 偽の API(:4000)と vite dev がいっしょに立つ
```

`shots/mock.mjs` の返事を、そのまま HTTP で出す小さなサーバ(`shots/api-server.mjs`)
が :4000 に立ち、vite には `VITE_DEV_TOKEN=mock` が渡る(`devAutoLogin()` が dev でだけ
効いて、入った状態から始まる)。Playwright の外 ── 普通のブラウザ、組み込みブラウザ、
スマホ ── でも、入った状態が開ける。ここで押した ☆ や 投稿は、どこにも届かない。

- 返事を決めるのは `mock.mjs` の `respond()` の一か所。絵を撮る Playwright(`pnpm run shots`)も、
  この偽サーバも、それを呼ぶ。
- 時刻は起動を基準に並ぶ(絵のほうは固定)。返事を用意していない口は、空で返して一度だけ
  名前を出す。
- 本物の gateway と同じ :4000 を取るので、どちらかしか同時には立てない。
- DM の WebSocket は、vite の proxy に `ws: true` が無いので、本物のときも届かない。
  アプリは静かに繋ぎ直す。
- 偽サーバだけなら `pnpm run mock:api`。

## ビルドして gateway から配る

```
npm run build           # web/build/ に静的ファイル出力
cp -r build/. ../elixir/priv/static/
```

gateway の `/` `/signup` `/timeline` `/app/callback` が `index.html` を返し、
`/static/*` がビルド済みアセットを返す。

## ページ

- `/` — トップ。レーンが二本（「はじめる」「もどる」）。
- `/signup` — 招待コード + なまえ + あいことば。
- `/login` — server-rendered（SPA ルートではない）。OAuth から自動で経由。
- `/app/callback` — `/oauth/authorize` からの帰り着点。
- `/timeline` — home / みんな / タグ。「もっと読む」ボタンでページ送り。

## 招待コードの発行

admin にログインして `/admin/invite_codes` で発行。一個発行 → 渡す → サインアップで
消費される。詳しくは elixir 側 `SukhiFedi.InviteCodes` を読む。
