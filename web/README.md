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
