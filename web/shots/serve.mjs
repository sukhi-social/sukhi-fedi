// build/ をそのまま出す、ちいさなサーバ。
//
// `vite preview` を使わないのは、あれが dev の proxy(`/api` `/login` を
// localhost:4000 へ)をそのまま引き継ぐから ── バックエンドが立って
// いないと `/login` へ行くだけで 502 になって、**その 502 の絵が
// login.png として残る**(2026-08-28、実際にそうなった)。
//
// 知らない道は index.html に落とす(adapter-static の fallback と同じ)。

import http from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.webmanifest': 'application/manifest+json',
  '.woff2': 'font/woff2'
};

export function serveBuild(root, port) {
  const server = http.createServer(async (req, res) => {
    const pathname = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const candidates = [
      path.join(root, pathname),
      path.join(root, pathname, 'index.html'),
      path.join(root, 'index.html')
    ];

    for (const file of candidates) {
      // build/ の外へ出ない。
      if (!file.startsWith(root)) continue;
      try {
        const body = await readFile(file);
        res.writeHead(200, {
          'content-type': MIME[path.extname(file)] ?? 'application/octet-stream'
        });
        res.end(body);
        return;
      } catch {
        /* 次の候補へ */
      }
    }

    res.writeHead(404).end('not found');
  });

  return new Promise((resolve) => {
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}
