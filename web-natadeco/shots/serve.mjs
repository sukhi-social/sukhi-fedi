// build/ を出す、ちいさな段取り ── サーバで描くようになったので(2026-09-03)、
// 出すものは二つ。
//
//   1. API の mock を HTTP で立てる。Node の中で描くときの fetch は
//      Playwright の route を通らない(あれはブラウザの中だけ)ので、
//      Node には本物の口が要る。答えは mock.mjs の ROUTES と同じ。
//   2. `node build`(adapter-node の出力)を、その mock を INTERNAL_API_URL
//      にして子プロセスで立てる。
//
// ブラウザ側の fetch(入っている人の取り直し・押したときの口)は、
// 今までどおり mock.mjs の installMocks が受ける。
//
// `vite preview` を使わないのは前からで、あれが dev の proxy(`/api` を
// localhost:4000 へ)をそのまま引き継ぐから ── バックエンドが立って
// いないと `/login` へ行くだけで 502 になって、その 502 の絵が
// login.png として残る(2026-08-28、実際にそうなった)。

import http from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { answer } from './mock.mjs';

function serveMockApi(port) {
  const server = http.createServer((req, res) => {
    const pathname = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const body = answer(pathname) ?? [];
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(body));
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve(server)));
}

function waitForListen(child) {
  return new Promise((resolve, reject) => {
    let out = '';
    const onData = (chunk) => {
      out += String(chunk);
      if (out.includes('Listening on')) resolve();
    };
    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    child.on('exit', (code) => reject(new Error(`node build exited (${code}):\n${out}`)));
  });
}

export async function serveBuild(root, port) {
  const apiPort = port + 1;
  const api = await serveMockApi(apiPort);

  const child = spawn(process.execPath, [path.join(root, 'index.js')], {
    env: {
      ...process.env,
      PORT: String(port),
      HOST: '127.0.0.1',
      // 本番と同じく、玄関(host)はヘッダで受ける ── travel の頁は
      // x-forwarded-host を見て部屋を分けるので、ORIGIN で固定しない。
      HOST_HEADER: 'x-forwarded-host',
      PROTOCOL_HEADER: 'x-forwarded-proto',
      INTERNAL_API_URL: `http://127.0.0.1:${apiPort}`
    },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  await waitForListen(child);

  return {
    close() {
      child.kill();
      api.close();
    }
  };
}
