import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';
import { readFileSync } from 'node:fs';

// リポジトリ直下の VERSION を、ビルドに焼く(「意見を送る」が添える版)。
// 読めなければ 'unknown' ── ビルドは止めない。
const appVersion = (() => {
  try {
    return readFileSync(new URL('../VERSION', import.meta.url), 'utf8').trim() || 'unknown';
  } catch {
    return 'unknown';
  }
})();

// /login と /settings/password は GET=SPA ページ・POST=バックエンド、と
// メソッドで持ち主が分かれる。dev プロキシは path 単位なので、GET は
// bypass で SvelteKit に返し、POST(資格情報・パスワード)だけ :4000 へ送る。
const getToSpa = (req: { method?: string; url?: string }) =>
  req.method === 'GET' ? req.url : undefined;

export default defineConfig({
  define: { __APP_VERSION__: JSON.stringify(appVersion) },
  plugins: [
    // SSG single-page mode: every client route resolves to `index.html`, the
    // SvelteKit runtime then renders the right page. The Elixir gateway is
    // taught explicitly which paths (`/`, `/signup`, `/timeline`,
    // `/app/callback`) should reach the SPA shell; everything else stays
    // owned by the server (login, OAuth, AP, admin).
    sveltekit({
      preprocess: vitePreprocess(),
      adapter: adapter({ fallback: 'index.html', precompress: false, strict: false }),
      paths: { base: '', relative: false },
      // SvelteKit が `/_app/version.json` を pollInterval 毎に取りに
      // いって、ビルドの version 文字列が変わったら `updated.current`
      // が true になる。+layout.svelte の UpdateBanner がそれを見て
      // 「新しい版が来ました、リロードしますか?」を出す。
      // 15s は気付きやすさ寄り(60s だと反映が遅く感じる)。GET 1本
      // /15s なのでサーバ負荷も小さい。
      version: { pollInterval: 15_000 }
    })
  ],
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://localhost:4000',
      '/oauth': 'http://localhost:4000',
      '/login': { target: 'http://localhost:4000', bypass: getToSpa },
      '/settings/password': { target: 'http://localhost:4000', bypass: getToSpa },
      '/logout': 'http://localhost:4000',
      // 利用規約・プライバシーは Elixir 側の静的ページ。signup の「部屋」が
      // /terms/body を fetch するので、dev でも :4000 へ流す。
      '/terms': 'http://localhost:4000',
      '/privacy': 'http://localhost:4000',
      '/.well-known': 'http://localhost:4000'
    }
  }
});
