import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [sveltekit()],
  server: {
    port: 5174,
    proxy: {
      '/api': 'http://localhost:4000',
      '/oauth': 'http://localhost:4000',
      '/login': 'http://localhost:4000'
    }
  }
});
