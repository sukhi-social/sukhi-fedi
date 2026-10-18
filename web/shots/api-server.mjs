// 偽の API サーバ ── 本物のブラウザから「入った状態」の sukhi を開くための。
//
//   pnpm run mock:api          # localhost:4000 で待つだけ(PORT で変えられる)
//   pnpm run dev:mock          # これと vite dev をいっしょに起こす(dev-mock.mjs)
//
// shots/mock.mjs の返事を、そのまま HTTP で出す。返事を決めるのは mock.mjs の
// respond() の一か所で、Playwright の route(絵を撮る道)も、ここも、それを呼ぶ
// ── 同じデータが、同じ形で出る。違うのは二つだけ:
//
//   ・時計。Playwright は page.clock で止められるが、本物のブラウザは止められない。
//     起動した時刻を基準に「何分前」を並べる(SUKHI_MOCK_NOW)。
//   ・開いたままの口(SSE)。route.fulfill は閉じるしかないが、ここは閉じずに保つ。
//     閉じると、アプリが繋ぎ直しつづける。
//
// vite dev は /api などを localhost:4000 へ流す(vite.config.ts の proxy)ので、
// 画面のコードも、vite.config も、何も変えずに、このサーバが本物のかわりに立つ。
// 本物のバックエンドと同じ :4000 を取るので、どちらかしか同時には立てない。
//
// 知らない口が来たら、空で返しながら一度だけ名前を出す(空っぽの画面に気づけるように)。
// モックの外(.well-known など)は 404。
//
// DM の WebSocket(/api/v1/streaming)は、vite の proxy に ws: true が付いていないので、
// 本物のバックエンドのときも、ここには届かない。アプリは静かに繋ぎ直す。

import http from 'node:http';
import { fileURLToPath } from 'node:url';

export async function startApiServer({ port = Number(process.env.PORT ?? 4000), quiet = false } = {}) {
  // mock.mjs が読まれる前に置く(NOW は読み込み時に決まる)。
  process.env.SUKHI_MOCK_NOW ??= new Date().toISOString();
  const { respond } = await import('./mock.mjs');

  const unknown = new Set();
  const open = new Set();

  const server = http.createServer((req, res) => {
    req.resume(); // POST の中身は見ない。読み捨てて、接続を使い回せるようにする
    const { pathname } = new URL(req.url ?? '/', 'http://localhost');
    const out = respond(pathname, req.method ?? 'GET');

    if (!out) {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end('{"error":"not a mocked path"}');
      return;
    }

    if (out.unknown) {
      const key = `${req.method} ${pathname}`;
      if (!quiet && !unknown.has(key)) console.log(`[mock-api] 返事を用意していない口(空で返した): ${key}`);
      unknown.add(key);
    }

    const headers = { 'cache-control': 'no-store' };
    if (out.contentType) headers['content-type'] = out.contentType;
    res.writeHead(out.status, headers);

    if (out.keepOpen) {
      // 開いたまま保つ。ブラウザが切ったら、こちらも閉じる。
      res.write(out.body);
      open.add(res);
      res.on('close', () => open.delete(res));
      return;
    }
    res.end(out.body);
  });

  await new Promise((resolve, reject) => {
    server.once('error', (err) => {
      if (err.code === 'EADDRINUSE') {
        reject(new Error(`:${port} はもう使われています(本物のバックエンドが立っていませんか)。PORT=… で変えられますが、vite.config.ts の proxy は :4000 を見ます。`));
      } else {
        reject(err);
      }
    });
    // vite の proxy が引く "localhost" と同じ名前で待つ(::1 と 127.0.0.1 の食い違いを避ける)。
    server.listen(port, 'localhost', resolve);
  });

  return {
    port,
    close() {
      for (const res of open) res.end();
      return new Promise((resolve) => server.close(resolve));
    }
  };
}

// `node shots/api-server.mjs` で直接動かしたときだけ、待ち受ける。
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const api = await startApiServer();
    console.log(`[mock-api] http://localhost:${api.port} で待っています(shots/mock.mjs の返事)。止めるのは Ctrl-C。`);
    const stop = () => api.close().then(() => process.exit(0));
    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);
  } catch (err) {
    console.error(`[mock-api] ${err.message}`);
    process.exit(1);
  }
}
