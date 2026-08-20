import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

// sukhi-fedi の web と同じ SSG の一枚もの。どの道も index.html に落ちて、
// あとは SvelteKit が中で行き先を決める。
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter({ fallback: 'index.html', precompress: false, strict: false }),
    paths: { base: '', relative: false }
  }
};

export default config;
