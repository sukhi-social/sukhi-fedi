// 偽の API(api-server.mjs)と vite dev を、いっしょに起こす。
//
//   pnpm run dev:mock                    # http://localhost:5173
//   pnpm run dev:mock -- --port 5174     # vite へはそのまま渡る
//
// vite には VITE_DEV_TOKEN=mock を渡す。devAutoLogin()(lib/auth.ts)が、dev でだけ、
// その token で「入った状態」から始めてくれる。どのブラウザで開いても、入った状態の
// sukhi が見える ── Playwright の外(このアプリの組み込みブラウザ、Safari、スマホ)でも。
//
// 本物のバックエンドに向けたいときは、これではなく ふつうの `pnpm run dev`。

import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { startApiServer } from './api-server.mjs';

let api;
try {
  api = await startApiServer();
} catch (err) {
  console.error(`[dev:mock] ${err.message}`);
  process.exit(1);
}
console.log(`[dev:mock] 偽の API が :${api.port} で待っています。vite dev を起こします(VITE_DEV_TOKEN=mock)。`);

// vite は bin/vite.js を exports に出していない。名前では引けないので、場所で指す。
const viteBin = fileURLToPath(new URL('../node_modules/vite/bin/vite.js', import.meta.url));
const vite = spawn(process.execPath, [viteBin, 'dev', ...process.argv.slice(2)], {
  stdio: 'inherit',
  env: { ...process.env, VITE_DEV_TOKEN: 'mock' }
});

let stopping = false;
async function stop(code = 0) {
  if (stopping) return;
  stopping = true;
  vite.kill('SIGTERM');
  await api.close();
  process.exit(code);
}

vite.on('exit', (code) => stop(code ?? 0));
process.on('SIGINT', () => stop(0));
process.on('SIGTERM', () => stop(0));
