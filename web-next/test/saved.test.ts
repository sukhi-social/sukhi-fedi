// SPDX-License-Identifier: AGPL-3.0-or-later
// しおりとお気に入りの棚。開けること、二つのタブがあること、入口がアバターの菜単にあることを確かめる。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5198;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4198', PUBLIC_ORIGIN: BASE },
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
async function text(path: string) {
  const res = await fetch(`${BASE}${path}`, { redirect: 'manual', headers: sid ? { cookie: sid } : {} });
  const set = res.headers.get('set-cookie')?.split(';')[0];
  if (set) sid = set;
  return { status: res.status, body: await res.text() };
}

test('しおり: 投稿が並び、二つのタブがあり、いまの棚に印が付く', async () => {
  const { status, body } = await text('/bookmarks');
  assert.equal(status, 200);
  assert.match(body, /id="bm-items"/);
  assert.match(body, /class="tab" href="\/bookmarks" aria-current="true"/);
  assert.match(body, /class="tab" href="\/favourites"/);
});

test('お気に入り: 同じ形で開く', async () => {
  const { status, body } = await text('/favourites');
  assert.equal(status, 200);
  assert.match(body, /id="fav-items"/);
  assert.match(body, /class="tab" href="\/favourites" aria-current="true"/);
});

test('入口は、アバターの菜単にある', async () => {
  const { body } = await text('/');
  assert.match(body, /href="\/bookmarks"/);
  assert.match(body, /href="\/favourites"/);
});
