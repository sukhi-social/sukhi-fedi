// SPDX-License-Identifier: AGPL-3.0-or-later
// ミュート・ブロック。プロフィールの「…」から掛け、設定の一覧から解く。gateway に届くことと、
// 返ってくる断片(プロフィールの右上の一塊 / 解いた行)を確かめる。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5196;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4196', PUBLIC_ORIGIN: BASE },
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
const log = async (): Promise<string[]> => (await fetch('http://localhost:4196/__mock/requests-log')).json();
const post = (path: string, fields: Record<string, string> = {}) => {
  const fd = new FormData();
  for (const [k, v] of Object.entries(fields)) fd.set(k, v);
  return go(path, { method: 'POST', body: fd, headers: { 'x-up-target': '#pf-actions', 'x-up-version': '3.15.0' } });
};

test('プロフィール: 他の人の頁には「…」があり、ミュートとブロックの口が付く(自分の頁には付かない)', async () => {
  const page = await (await go('/@nabi')).text();
  assert.match(page, /id="pf-actions"/);
  assert.match(page, /action="\/accounts\/\d+\/mute"/);
  assert.match(page, /action="\/accounts\/\d+\/block"[^>]*up-confirm=/);
  const mine = await (await go('/@kuro')).text();
  assert.doesNotMatch(mine, /id="pf-actions"/);
});

test('ミュート: gateway に届き、「ミュート中」と「ミュートを解く」で組みなおされる', async () => {
  const before = (await log()).length;
  const res = await post('/accounts/2/mute');
  assert.equal(res.status, 200);
  const frag = await res.text();
  assert.match(frag, /id="pf-actions"/);
  assert.match(frag, /ミュート中/);
  assert.match(frag, /action="\/accounts\/2\/unmute"/);
  assert.deepEqual((await log()).slice(before), ['accounts/2/mute']);
});

test('ブロック: フォローのボタンが消え、「ブロックを解く」が出る', async () => {
  const res = await post('/accounts/2/block');
  const frag = await res.text();
  assert.match(frag, /ブロック中/);
  assert.match(frag, /action="\/accounts\/2\/unblock"/);
  assert.doesNotMatch(frag, /follow-btn/);
});

test('一覧: ブロック中とミュート中の人が並び、解くと行が空になる', async () => {
  const page = await (await go('/settings/people')).text();
  assert.match(page, /id="bl-\d+"/);
  assert.match(page, /id="mu-\d+"/);
  const before = (await log()).length;
  const res = await post('/accounts/2/unblock', { row: 'bl-2' });
  assert.equal(res.status, 200);
  assert.match(await res.text(), /<article class="account-row" id="bl-2"><\/article>/);
  assert.deepEqual((await log()).slice(before), ['accounts/2/unblock']);
});

test('知らない動詞は、何も送らずにホームへ', async () => {
  const before = (await log()).length;
  const res = await post('/accounts/2/whatever');
  assert.equal(res.status, 303);
  assert.equal((await log()).length, before);
});
