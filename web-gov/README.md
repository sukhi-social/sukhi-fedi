<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# web-gov

迎える人の道具(静的な Svelte 5 の頁)。申し込みを読み、迎える・見送る。
仕組みと、置き方は [`docs/JOIN.md`](../docs/JOIN.md)(web-gov の節)。

```bash
pnpm install
pnpm test    # vitest
pnpm dev     # VITE_API_BASE に、api の origin
VITE_API_BASE=https://sukhi.social VITE_CLIENT_ID=<client_id> pnpm build
```

ログインは OAuth(PKCE)。登録した `redirect_uri` は、この頁のトップ(`origin/`)。
