// SPDX-License-Identifier: AGPL-3.0-or-later
// UI のモックを、本物の CSS・字・Unpoly・Alpine のまま、並べて見る作業机。依存ゼロ(Node だけ)。
//
//   node serve.mjs            # http://localhost:5180  ギャラリー
//   PORT=5181 node serve.mjs
//
// 何が並ぶか(いずれも、フォルダを足すだけ。登録はいらない):
//   mocks/<名前>/index.html     ここで書くモック。先頭が <!--lab:shell--> なら、<main> の中身だけ書けばよい(下の shell())
//   external/<名前>/dist/       import.mjs が束ねた、よそのモック(React など)。git には入れない
//   lab/live.json               いま動いている web-next(pnpm run dev:mock, :5174)の頁。比べる相手
//
// 本物の server/assets.ts と同じ URL で CSS・JS・字を出す(MOUNTS)。だから、モックの HTML は、
// そのまま views/*.ts に移せる。変えたら、あちらの表が正。

import { createServer } from 'node:http';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { extname, join, normalize, sep } from 'node:path';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..'); // web-next/
const PORT = Number(process.env.PORT ?? 5180);
const LIVE = process.env.LIVE_URL ?? 'http://localhost:5174';
const nm = join(root, 'node_modules') + sep;

// url の前置き → ディスク。server/assets.ts の MOUNTS と同じ(長い前置きが先)。
const MOUNTS = [
  ['/assets/vendor/unpoly/', `${nm}unpoly/`],
  ['/assets/vendor/alpine/', `${nm}alpinejs/dist/`],
  ['/assets/fonts/', `${nm}@fontsource/`],
  ['/twemoji/svg/', `${nm}@twemoji/svg/`],
  ['/assets/', join(root, 'public') + sep],
  // 本物は / 直下に favicon などを置く。モックの頁が引くぶんだけ。
  ['/favicon.png', join(root, 'public', 'favicon.png')],
  ['/avatar-default.svg', join(root, 'public', 'avatar-default.svg')],
];

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
};

// base の外へ出るパスは、見つからなかったことにする。
function under(base, rel) {
  let full;
  try {
    full = normalize(join(base, decodeURIComponent(rel)));
  } catch {
    return null;
  }
  const b = base.endsWith(sep) ? base : base + sep;
  return full === base || full.startsWith(b) ? full : null;
}

function fileOf(pathname) {
  for (const [prefix, target] of MOUNTS) {
    if (!pathname.startsWith(prefix)) continue;
    const full = target.endsWith(sep) ? under(target, pathname.slice(prefix.length)) : target;
    if (full && existsSync(full) && statSync(full).isFile()) return full;
  }
  return null;
}

// tokens.css の暗い色は @media (prefers-color-scheme: dark) の中にしかない(端末まかせ。切り替えは無い)。
// ギャラリーから明暗を切り替えられるよう、同じ中身を :root[data-theme="dark"] にも出し、
// 明るいほうを選んだときは @media のほうを引っこめる。値は増やさない ── 元の一か所を、そのまま写す。
function themable(css) {
  return css.replace(
    /@media \(prefers-color-scheme: dark\) \{\s*:root \{([\s\S]*?)\n  \}\n\}/,
    (_all, body) =>
      `@media (prefers-color-scheme: dark) {\n  :root:not([data-theme="light"]) {${body}\n  }\n}\n:root[data-theme="dark"] {${body}\n}`
  );
}

// ── モック一覧 ──────────────────────────────────────────────

const meta = (src, name) => src.match(new RegExp(`<meta\\s+name="${name}"\\s+content="([^"]*)"`, 'i'))?.[1] ?? '';

function scenesOf(src) {
  // <meta name="lab:scenes" content="fresh=あたらしい便りがある;quiet=変わりなし">
  return meta(src, 'lab:scenes')
    .split(';')
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => {
      const [id, ...label] = s.split('=');
      return { id: id.trim(), label: label.join('=').trim() || id.trim() };
    });
}

function listMocks() {
  const out = [];
  const dirs = (d) => (existsSync(d) ? readdirSync(d, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name) : []);
  for (const name of dirs(join(here, 'mocks')).sort()) {
    const f = join(here, 'mocks', name, 'index.html');
    if (!existsSync(f)) continue;
    const src = readFileSync(f, 'utf8');
    out.push({
      id: name,
      kind: 'native',
      title: src.match(/<title>([^<]*)<\/title>/)?.[1] ?? name,
      desc: meta(src, 'lab:desc'),
      scenes: scenesOf(src),
      url: `/m/${name}/`,
    });
  }
  for (const name of dirs(join(here, 'external')).sort()) {
    const f = join(here, 'external', name, 'dist', 'index.html');
    if (!existsSync(f)) continue;
    const src = readFileSync(f, 'utf8');
    out.push({
      id: name,
      kind: 'external',
      title: src.match(/<title>([^<]*)<\/title>/)?.[1] || name,
      desc: 'import.mjs で取りこんだ、よその作りのモック',
      scenes: [],
      url: `/x/${name}/`,
    });
  }
  const livePath = join(here, 'lab', 'live.json');
  const live = existsSync(livePath) ? JSON.parse(readFileSync(livePath, 'utf8')) : [];
  for (const l of live) {
    out.push({
      id: `live:${l.path}`,
      kind: 'live',
      title: l.title,
      desc: `動いている web-next(${LIVE})`,
      scenes: [],
      url: LIVE + l.path,
    });
  }
  return out;
}

// ── shell: <main> の中身だけで書けるモック ─────────────────────

const HEAD_TAGS = /^\s*(?:<title[\s\S]*?<\/title>|<meta\b[^>]*>|<link\b[^>]*>|<style[\s\S]*?<\/style>|<script\b[\s\S]*?<\/script>|<!--[\s\S]*?-->)/;

function shell(src) {
  // 先頭の <title> <meta> <link> <style> <script> と、<!-- --> は head へ。残りが <main> の中身。
  let rest = src.replace(/^\s*<!--lab:shell-->/, '');
  let head = '';
  for (let m; (m = rest.match(HEAD_TAGS)); ) {
    head += m[0].trim() + '\n  ';
    rest = rest.slice(m[0].length);
  }
  const tpl = readFileSync(join(here, 'lab', 'shell.html'), 'utf8');
  let page = tpl.replace('{{head}}', () => head).replace('{{body}}', () => rest);
  // いまのページに、ナビの印を付ける。<meta name="lab:nav" content="home|compose|notifications|search|none">
  const cur = meta(src, 'lab:nav') || 'home';
  const href = { home: '/', compose: '/compose', notifications: '/notifications', search: '/search' }[cur];
  page = page.replace(/aria-current="page"/g, 'aria-current=""');
  if (href) page = page.replace(new RegExp(`(href="${href}"[^>]*?)aria-current=""`, 'g'), '$1aria-current="page"');
  return page;
}

// ── 配る ──────────────────────────────────────────────────────

function send(res, status, body, type) {
  res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' });
  res.end(body);
}

function sendFile(res, full) {
  const type = MIME[extname(full)] ?? 'application/octet-stream';
  let body = readFileSync(full);
  if (full.endsWith(`${sep}css${sep}tokens.css`)) body = themable(body.toString('utf8'));
  send(res, 200, body, type);
}

function serveDir(res, base, rel, { index = 'index.html', wrap = false } = {}) {
  let full = under(base, rel || index);
  if (full && existsSync(full) && statSync(full).isDirectory()) full = join(full, index);
  if (!full || !existsSync(full) || !statSync(full).isFile()) return send(res, 404, 'ない', 'text/plain; charset=utf-8');
  if (wrap && full.endsWith(`${sep}index.html`)) {
    const src = readFileSync(full, 'utf8');
    if (/^\s*<!--lab:shell-->/.test(src)) return send(res, 200, shell(src), MIME['.html']);
  }
  sendFile(res, full);
}

const server = createServer((req, res) => {
  const { pathname } = new URL(req.url ?? '/', 'http://x');

  if (pathname === '/') return serveDir(res, join(here, 'lab'), 'index.html');
  if (pathname === '/_lab/mocks.json') return send(res, 200, JSON.stringify(listMocks()), MIME['.json']);
  if (pathname.startsWith('/_lab/')) return serveDir(res, join(here, 'lab'), pathname.slice(6));

  let m;
  if ((m = pathname.match(/^\/m\/([a-z0-9-]+)\/(.*)$/))) return serveDir(res, join(here, 'mocks', m[1]), m[2], { wrap: true });
  if ((m = pathname.match(/^\/x\/([a-z0-9-]+)\/(.*)$/))) return serveDir(res, join(here, 'external', m[1], 'dist'), m[2]);

  const asset = fileOf(pathname);
  if (asset) return sendFile(res, asset);
  send(res, 404, 'ない', 'text/plain; charset=utf-8');
});

server.listen(PORT, () => console.log(`ui-lab: http://localhost:${PORT}  (live: ${LIVE})`));
