import adapter from '@sveltejs/adapter-node';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

// サーバで描く(2026-09-03 から)。Node が一つ、BEAM の横に立つ ──
// HTML の要求だけ Elixir がそこへ回し、API・連合・WS は今までどおり
// Elixir が受ける。公開の頁は load で取ってサーバで描き、ログインが
// 要る頁は `ssr = false` でブラウザが描く(トークンは localStorage に
// あって、サーバは誰が見ているか知らないので)。
//
// `build/client/` が静的なもの(Elixir の override へ rsync)、
// `build/index.js` が Node で動くもの(web-natadeco/Dockerfile)。
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter({ out: 'build' }),
    paths: { base: '', relative: false }
  }
};

export default config;
