// SPDX-License-Identifier: AGPL-3.0-or-later
// ふたりの部屋: 一覧・部屋・送る・新しい部屋。gateway に届くことと、頁の形を確かめる。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5200;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4200', PUBLIC_ORIGIN: BASE },
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
const log = async (): Promise<string[]> => (await fetch('http://localhost:4200/__mock/requests-log')).json();
const post = (path: string, fields: Record<string, string> = {}) => {
  const fd = new FormData();
  for (const [k, v] of Object.entries(fields)) fd.set(k, v);
  return go(path, { method: 'POST', body: fd });
};

const scheduled = async (): Promise<{ params: { text: string } }[]> => (await fetch('http://localhost:4200/api/v1/scheduled_statuses')).json();

test('一覧: 相手ごとの部屋が並び、数は出さず、ひらいていない部屋にことばだけ', async () => {
  const page = await (await go('/rooms')).text();
  assert.match(page, /class="room-row" href="\/rooms\/c1"/);
  assert.match(page, /class="room-row" href="\/rooms\/c2"/);
  assert.match(page, /ひらいていません/);
  assert.match(page, /내일 시간 괜찮으세요\?/);
  assert.doesNotMatch(page, /@kuro 내일/); // 頭の @相手 は見せない
});

test('部屋: 古い順に並び、頭の @相手 は外れ、書く欄がある', async () => {
  const page = await (await go('/rooms/c1')).text();
  const a = page.indexOf('こんばんは');
  const b = page.indexOf('내일 시간');
  assert.ok(a > 0 && b > a, '古いものが上');
  assert.doesNotMatch(page, /@nabi こんばんは/);
  assert.match(page, /<form class="room-write" method="post" action="\/rooms\/c1">/);
  assert.match(page, /name="body"/);
});

test('送る: 宛先の @ が本文の頭に付き、直前の投稿への返信として、お預かりに入る', async () => {
  const before = (await scheduled()).length;
  const res = await post('/rooms/c1', { body: '  はい、だいじょうぶです。 ' });
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/rooms/c1');
  const got = (await scheduled()).slice(before);
  assert.equal(got.length, 1);
  assert.equal(got[0].params.text, '@nabi はい、だいじょうぶです。');
});

test('送る: 空なら、送らずに戻す', async () => {
  const before = (await scheduled()).length;
  const res = await post('/rooms/c1', { body: '   ' });
  assert.equal(res.status, 422);
  assert.equal((await scheduled()).length, before);
});

test('新しい部屋: 部屋のある人は、その部屋へ。無い人は、書く欄だけの部屋へ', async () => {
  const have = await post('/rooms/new', { acct: '@nabi' });
  assert.equal(have.status, 303);
  assert.equal(have.headers.get('location'), '/rooms/c1');
  const fresh = await post('/rooms/new', { acct: '@kuro_friend' });
  assert.ok([303, 422].includes(fresh.status));
});

test('はじめの一通: 部屋がまだ無い相手へも、@ を付けて送れる', async () => {
  const page = await (await go('/rooms/with/nabi')).text();
  assert.match(page, /action="\/rooms\/with\/nabi"/);
  const before = (await scheduled()).length;
  const res = await post('/rooms/with/nabi', { body: 'はじめまして' });
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/rooms');
  assert.equal((await scheduled()).slice(before)[0].params.text, '@nabi はじめまして');
});

test('入口は、アバターの菜単にある', async () => {
  assert.match(await (await go('/')).text(), /role="menuitem" href="\/rooms"/);
});
