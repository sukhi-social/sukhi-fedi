import adapter from '@sveltejs/adapter-node';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [
    // サーバで描く(2026-09-03 から)。Node が一つ、gateway の前の web(front)
    // として立つ ── 頁はここが答え、API・連合・WS は gateway が受ける。
    // 公開の頁は load で取ってサーバで描き、ログインが要る頁は `ssr = false`
    // でブラウザが描く(トークンは localStorage にあって、サーバは誰が見て
    // いるか知らないので)。
    //
    // `build/client/` が静的なもの、`build/index.js` が Node で動くもの。
    // どちらも同じ image から立つ(web-natadeco/Dockerfile)。
    sveltekit({
      preprocess: vitePreprocess(),
      adapter: adapter({ out: 'build' }),
      paths: { base: '', relative: false }
    })
  ],
  server: {
    port: 5174,
    proxy: {
      '/api': 'http://localhost:4000',
      '/oauth': 'http://localhost:4000',
      '/login': 'http://localhost:4000'
    }
  }
});
