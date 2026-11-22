// SPDX-License-Identifier: AGPL-3.0-or-later
// ふたりの部屋の呼び鈴: 部屋の頁の形・ログだけの取りなおし(GET /rooms/:id/talk)・呼び鈴(SSE)と、その向こうの WebSocket。
// 偽の gateway(Bearer を見る WebSocket を持つ)と郵便局を子プロセスで立てて、層ごとに歩く。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { isThisConversation } from '../server/direct.ts';
import { loggedOutServer, openBell, streamsBecome } from './bell.ts';

const PORT = 5247;
const MOCK = 4247;
const BASE = `http://localhost:${PORT}`;
const M = `http://localhost:${MOCK}/__mock`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: String(MOCK), PUBLIC_ORIGIN: BASE },
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

let sid = '';
async function go(path: string, init: RequestInit = {}) {
  const res = await fetch(`${BASE}${path}`, {
    redirect: 'manual',
    ...init,
    headers: { ...(sid ? { cookie: sid } : {}), origin: BASE, ...init.headers }
  });
  const set = res.headers.get('set-cookie')?.split(';')[0];
  if (set) sid = set;
  return res;
}
const post = (path: string, fields: Record<string, string> = {}) => {
  const fd = new FormData();
  for (const [k, v] of Object.entries(fields)) fd.set(k, v);
  return go(path, { method: 'POST', body: fd });
};
const mockPost = (path: string) => fetch(`${M}/${path}`, { method: 'POST' });
const log = async (): Promise<string[]> => (await fetch(`${M}/requests-log`)).json();
const talks = (n: number) => streamsBecome(M, 'talks', n);
const roomBell = (id: string, init: RequestInit = {}) => openBell(`${BASE}/rooms/${id}/stream`, { ...init, headers: { ...(sid ? { cookie: sid } : {}), ...init.headers } });

// gateway が流す一通(Mastodon と同じ形: payload は JSON の文字列)。
const frame = (event: string, payload: unknown) => JSON.stringify({ stream: ['direct'], event, payload: JSON.stringify(payload) });

// ── 単体: この会話のことか ────────────────────────────────────────

test('この会話のことか: conversation で、id が同じものだけ。読めない形は、すべて false', () => {
  assert.equal(isThisConversation(frame('conversation', { id: 'c1' }), 'c1'), true);
  assert.equal(isThisConversation(frame('conversation', { id: 7 }), '7'), true); // 数でも、同じ id
  assert.equal(isThisConversation(JSON.stringify({ event: 'conversation', payload: { id: 'c1' } }), 'c1'), true); // payload が文字列でなくても
  assert.equal(isThisConversation(frame('conversation', { id: 'c2' }), 'c1'), false);
  assert.equal(isThisConversation(frame('update', { id: 'c1' }), 'c1'), false);
  assert.equal(isThisConversation(frame('conversation', {}), 'c1'), false);
  assert.equal(isThisConversation(frame('conversation', null), 'c1'), false);
  assert.equal(isThisConversation('{"event":"conversation","payload":"not json"}', 'c1'), false);
  assert.equal(isThisConversation('not json', 'c1'), false);
  assert.equal(isThisConversation(undefined, 'c1'), false);
  assert.equal(isThisConversation(new Uint8Array(2), 'c1'), false);
});

// ── 頁とログ ──────────────────────────────────────────────────────

const inner = (html: string): string => /<div class="room-log stack"[^>]*>([\s\S]*?)<\/div>\s*<form class="room-write"/.exec(html)?.[1] ?? '';

test('部屋の頁: ログは一つの箱に入り、あるときだけ呼び鈴の道がつく。書く欄は箱の外', async () => {
  const page = await (await go('/rooms/c1')).text();
  assert.match(page, /<div class="room-log stack" data-room-live="\/rooms\/c1">/);
  assert.equal(page.match(/class="room-msg /g)?.length, 2);
  assert.ok(page.indexOf('class="room-talk"') < page.indexOf('<form class="room-write"'));
  assert.doesNotMatch(inner(page), /<textarea/); // 箱の中身を差しかえても、書きかけには、ふれない

  // まだ部屋が無い(はじめの一通)ときは、箱はあるが、呼び鈴の道は無い。
  const fresh = await (await go('/rooms/with/nabi')).text();
  assert.match(fresh, /<div class="room-log stack">/);
  assert.doesNotMatch(fresh, /data-room-live/);
});

test('ログだけの取りなおし: 頁の箱の中身と、同じ描きかた。枠も書く欄も付かない', async () => {
  const page = await (await go('/rooms/c1')).text();
  const res = await go('/rooms/c1/talk');
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type') ?? '', /^text\/html/);
  const talk = await res.text();
  assert.equal(talk.match(/class="room-msg /g)?.length, 2);
  assert.doesNotMatch(talk, /<!doctype|<form|<header|<textarea/i);
  assert.equal(talk.trim(), inner(page).trim());
});

test('ログだけの取りなおしは、見ているので、読んだ印も付く(一覧の「ひらいていません」が残らない)', async () => {
  const before = (await log()).filter((l) => l === 'conversations/c1/read').length;
  await go('/rooms/c1/talk');
  assert.equal((await log()).filter((l) => l === 'conversations/c1/read').length, before + 1); // c1 は、偽 gateway では unread のまま
});

test('ログだけの取りなおしは、頁の「お知らせ」を持っていかない(頁が、ちゃんと見せる)', async () => {
  await post('/rooms/c1', { body: 'ありがとう' }); // お預かり → flash が立つ
  await go('/rooms/c1/talk'); // 裏の取りなおし
  const page = await (await go('/rooms/c1')).text();
  assert.match(page, /<p class="notice" role="status">/);
});

test('ない部屋には、404(EventSource は、そこで繋ぎ直すのをやめる)', async () => {
  assert.equal((await go('/rooms/bad.id/talk')).status, 404);
  assert.equal((await go('/rooms/bad.id/stream')).status, 404);
});

test('入っていない人には、ログインの頁へ追わせず、401(fetch が、頁の中に差してしまわないように)', async () => {
  const out = await loggedOutServer(5248);
  try {
    for (const path of ['/rooms/c1/talk', '/rooms/c1/stream']) {
      const res = await fetch(`${out.base}${path}`, { redirect: 'manual' });
      assert.equal(res.status, 401, path);
    }
  } finally {
    out.stop();
  }
});

// ── 呼び鈴 ────────────────────────────────────────────────────────

test('呼び鈴: この部屋のぶんだけ、中身なしで鳴る。token は、握手の header にあって、URL にない', async () => {
  await talks(0);
  const bell = await roomBell('c1');
  try {
    assert.equal(bell.res.status, 200);
    assert.match(bell.res.headers.get('content-type') ?? '', /^text\/event-stream/);
    assert.equal(bell.res.headers.get('x-accel-buffering'), 'no');
    assert.equal(bell.res.headers.get('cache-control'), 'no-store');
    assert.ok(await bell.until(/retry: 5000\n\n/));
    await talks(1);

    // 偽 gateway は、Bearer の無い握手を 401 で断る。繋がっているなら、header で渡っている ── URL には、何も乗せない。
    const hand = (await log()).filter((l) => l.startsWith('ws '));
    assert.deepEqual(hand.slice(-1), ['ws /api/v1/streaming?stream=direct']);

    await mockPost('conversation?id=c2'); // よその部屋: 鳴らさない
    await mockPost('conversation?raw=not-json'); // 形がちがう: 鳴らさない
    await mockPost(`conversation?raw=${encodeURIComponent(frame('update', { id: 'c1' }))}`); // 会話ではない: 鳴らさない
    await mockPost('conversation?id=c1'); // この部屋: 鳴る
    assert.ok(await bell.until(/event: poke\ndata: 1\n\n/));
    assert.equal(bell.text().match(/event: poke/g)?.length, 1);
    assert.doesNotMatch(bell.text(), /c1|c2|not-json|update/); // 中身は、一つも流れない

    await mockPost('conversation?id=c1');
    await bell.until(/(event: poke[\s\S]*){2}/);
  } finally {
    bell.close();
  }
  await talks(0); // ブラウザが去れば、gateway への WebSocket も閉じる
});

test('呼び鈴: gateway が WebSocket を閉じたら、こちらも閉じる(ブラウザが繋ぎ直す)', async () => {
  await talks(0);
  const bell = await roomBell('c1');
  assert.ok(await bell.until(/retry: 5000/));
  await talks(1);
  await mockPost('stream-end');
  assert.equal(await bell.until(/never-appears/, 3000), false);
  await talks(0);
});

test('呼び鈴: gateway が握手を断る(503)ときは、繋がずに閉じる。ブラウザが、あとで繋ぎ直す', async () => {
  await mockPost('stream-end?down=1');
  try {
    const bell = await roomBell('c1');
    assert.ok(await bell.until(/retry: 5000/));
    assert.equal(await bell.until(/never-appears/, 3000), false);
    await talks(0);
  } finally {
    await mockPost('stream-end?down=0');
  }
});

test('呼び鈴: HEAD では gateway の WebSocket を残さない', async () => {
  await talks(0);
  const res = await go('/rooms/c1/stream', { method: 'HEAD' });
  assert.equal(res.status, 200);
  await talks(0);
});
