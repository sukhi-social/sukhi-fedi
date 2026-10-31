// SPDX-License-Identifier: AGPL-3.0-or-later
// アプリらしさ: manifest・service worker の配りかた・知らせ(push)の口・頁の枠。
// 偽の gateway と郵便局を子プロセスで立てて、端から端まで歩く。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { alertsFor, hasPushScope, readPushConfig } from '../server/push.ts';

const PORT = 5197;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  // public/sw.js は、ビルドで作るもの(git には無い)。
  const built = spawnSync('node', ['scripts/build-sw.mjs'], { encoding: 'utf8' });
  assert.equal(built.status, 0, built.stderr);

  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4197', PUBLIC_ORIGIN: BASE },
    stdio: 'ignore'
  });
  for (let i = 0; i < 50; i++) {
    try {
      if ((await fetch(`${BASE}/login`)).status < 500) return;
    } catch {
      // まだ立っていない。
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('web-next did not start');
});

after(() => child?.kill());

// ── 純粋なところ ─────────────────────────────────────────────────
test('instance の返事から鍵と一覧を読む。欠けていたら「やっていない」に倒れる', () => {
  assert.deepEqual(readPushConfig({ configuration: { vapid: { public_key: 'KEY' }, direct_types: ['mention', 7] } }), {
    serverKey: 'KEY',
    directTypes: ['mention']
  });
  assert.deepEqual(readPushConfig({ configuration: { vapid: { public_key: '' } } }), { serverKey: null, directTypes: [] });
  assert.deepEqual(readPushConfig(null), { serverKey: null, directTypes: [] });
});

test('alerts は、gateway が決めた一覧そのまま。足さない。空なら何も鳴らさない', () => {
  assert.deepEqual(alertsFor(['mention', 'follow_request']), { mention: true, follow_request: true });
  assert.deepEqual(alertsFor([]), {});
});

test('push の scope があるか', () => {
  assert.equal(hasPushScope('read write follow push'), true);
  assert.equal(hasPushScope('read write'), false);
  assert.equal(hasPushScope(undefined), false);
});

// ── manifest ─────────────────────────────────────────────────────
test('manifest: 入口は / 、アイコンは 192・512・maskable がそろい、ファイルがある', async () => {
  const m = JSON.parse(readFileSync('public/manifest.webmanifest', 'utf8'));
  assert.equal(m.start_url, '/');
  assert.equal(m.display, 'standalone');
  const sizes = m.icons.map((i: { sizes: string; purpose: string }) => `${i.sizes}:${i.purpose}`);
  assert.ok(sizes.includes('192x192:any') && sizes.includes('512x512:any') && sizes.includes('512x512:maskable'));
  for (const icon of m.icons) {
    const res = await fetch(`${BASE}${icon.src}`);
    assert.equal(res.status, 200, icon.src);
    assert.equal(res.headers.get('content-type'), 'image/png');
  }
  assert.equal(m.share_target.action, '/compose');
});

test('共有(share_target)から来たら、書く欄に題・本文・URL が入る。同じものは重ねない', async () => {
  const q = new URLSearchParams({ title: 'いい頁', text: 'これ、すき', url: 'https://example.com/a' });
  const page = await (await fetch(`${BASE}/compose?${q}`)).text();
  assert.match(page, /<textarea[^>]*>いい頁\nこれ、すき\nhttps:\/\/example\.com\/a<\/textarea>/);
  const dup = await (await fetch(`${BASE}/compose?${new URLSearchParams({ text: 'https://example.com/a', url: 'https://example.com/a' })}`)).text();
  assert.match(dup, /<textarea[^>]*>https:\/\/example\.com\/a<\/textarea>/);
});

// ── service worker ───────────────────────────────────────────────
test('/sw: JS で、いつも取りなおす(no-cache)。Serwist ごと束ねてある', async () => {
  const res = await fetch(`${BASE}/sw`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type') ?? '', /javascript/);
  assert.equal(res.headers.get('cache-control'), 'no-cache');
  const src = await res.text();
  assert.match(src, /sukhi-pages/);
  assert.ok(!/from\s*["']serwist["']/.test(src), 'import が残っていない(束ねてある)');
});

// ── 頁の枠 ────────────────────────────────────────────────────────
test('頁の枠: 名前・全画面・つながっていない帯・pwa.js が付く', async () => {
  const page = await (await fetch(`${BASE}/settings`)).text();
  assert.match(page, /<meta name="application-name" content="sukhi-fedi"/);
  assert.match(page, /viewport-fit=cover/);
  assert.match(page, /id="net-banner"[^>]*hidden/);
  assert.match(page, /\/assets\/js\/pwa\.js\?v=/);
  assert.match(page, /id="pwa-install-dialog"[^>]*hidden/);
  assert.match(page, /data-pwa-step="welcome"/);
  assert.match(page, /data-pwa-step="prompt"/);
  assert.match(page, /data-pwa-step="installed"/);
  assert.match(page, /data-pwa-step="skipped"/);
  assert.match(page, /data-pwa-next/);
  assert.match(page, /data-pwa-install/);
  assert.match(page, /data-pwa-dismiss/);
});

test('pwa.js: Chrome の beforeinstallprompt を受け止め、歓迎のウィンドウからインストール推薦を行う', () => {
  const src = readFileSync('public/js/pwa.js', 'utf8');
  assert.match(src, /addEventListener\("beforeinstallprompt"/);
  assert.match(src, /addEventListener\("appinstalled"/);
  assert.match(src, /data-pwa-next/);
  assert.match(src, /data-pwa-install/);
  assert.match(src, /deferredPrompt\.prompt\(\)/);
  assert.match(src, /setStep\("installed"\)/);
  assert.match(src, /setStep\("skipped"\)/);
});

test('設定の頁に、知らせの入り切りがある(自動では、訊かない)', async () => {
  const page = await (await fetch(`${BASE}/settings`)).text();
  assert.match(page, /x-data="pushToggle"/);
});

// ── 知らせの口 ────────────────────────────────────────────────────
const post = (path: string, body: Record<string, string>) =>
  fetch(`${BASE}${path}`, { method: 'POST', headers: { origin: BASE }, body: new URLSearchParams(body) });

test('/push/config: 鍵があり、鳴らす先(direct_types)があれば configured', async () => {
  const res = await fetch(`${BASE}/push/config`);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  const c = await res.json();
  assert.equal(c.configured, true);
  assert.equal(c.scopeOk, true);
  assert.match(c.serverKey, /^B[\w-]{60,}$/);
});

test('/push/subscribe: 形がおかしいものは 422(https の endpoint と鍵が要る)', async () => {
  assert.equal((await post('/push/subscribe', { endpoint: 'http://x', p256dh: 'a', auth: 'b' })).status, 422);
  assert.equal((await post('/push/subscribe', { endpoint: 'https://push.example/x', p256dh: '', auth: 'b' })).status, 422);
  assert.equal((await post('/push/subscribe', { endpoint: 'https://push.example/x', p256dh: 'a', auth: 'b' })).status, 200);
});

test('/push/subscribe: 別の origin からの POST は、戸が閉まっている(403)', async () => {
  const res = await fetch(`${BASE}/push/subscribe`, {
    method: 'POST',
    headers: { origin: 'https://evil.example' },
    body: new URLSearchParams({ endpoint: 'https://push.example/x', p256dh: 'a', auth: 'b' })
  });
  assert.equal(res.status, 403);
});

// ── 落ちているとき ──────────────────────────────────────────────
test('頁の枠: 「サーバーが応えない」の文も帯に入っている(隠れた状態で)', async () => {
  const page = await (await fetch(`${BASE}/login`)).text();
  assert.match(page, /data-net="offline"/);
  assert.match(page, /data-net="server"[^>]*hidden/);
});

test('service worker: 502/503/504 は fetch の失敗として扱い、頁にはエラー画面を出す', () => {
  const src = readFileSync('sw/sw.js', 'utf8');
  assert.match(src, /UPSTREAM_DOWN = new Set\(\[502, 503, 504\]\)/);
  assert.match(src, /networkTimeoutSeconds: 15/);
});

test('pwa.js: Unpoly の 502 で、差し替えを止めて帯を出す', () => {
  const src = readFileSync('public/js/pwa.js', 'utf8');
  assert.match(src, /up:fragment:loaded/);
  assert.match(src, /\[502, 503, 504\]/);
});
