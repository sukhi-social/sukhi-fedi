// SPDX-License-Identifier: AGPL-3.0-or-later
// ご意見とおしらせ。フォームが gateway に届くことと、おしらせが文字だけで出て、閉じられることを確かめる。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5197;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
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
const log = async (): Promise<string[]> => (await fetch('http://localhost:4197/__mock/requests-log')).json();
const post = (path: string, fields: Record<string, string> = {}, headers: Record<string, string> = {}) => {
  const fd = new FormData();
  for (const [k, v] of Object.entries(fields)) fd.set(k, v);
  return go(path, { method: 'POST', body: fd, headers });
};

test('ホーム: まだ読んでいないおしらせが一枚、文字だけで出る', async () => {
  const page = await (await go('/')).text();
  assert.match(page, /<aside class="announce" id="an-a1"/);
  assert.match(page, /action="\/announcements\/a1\/dismiss"/);
  assert.doesNotMatch(page, /<aside class="announce"[^]*<script/);
});

test('おしらせ: 閉じると gateway に届き、その枠が空になる', async () => {
  const before = (await log()).length;
  const res = await post('/announcements/a1/dismiss', {}, { 'x-up-target': '#an-a1', 'x-up-version': '3.15.0' });
  assert.equal(res.status, 200);
  assert.match(await res.text(), /<div id="an-a1"><\/div>/);
  assert.deepEqual((await log()).slice(before), ['announcements/a1/dismiss']);
});

test('ご意見: 頁が開き、送ると gateway に届いて「届きました」', async () => {
  const page = await (await go('/feedback')).text();
  assert.match(page, /<textarea name="body"/);
  const before = (await log()).length;
  const res = await post('/feedback', { body: '  ここが分かりにくかったです  ' });
  assert.equal(res.status, 200);
  assert.match(await res.text(), /届きました/);
  assert.deepEqual((await log()).slice(before), ['feedback']);
});

test('ご意見: 空と長すぎは、送らずに、書いたものを残して戻す', async () => {
  const before = (await log()).length;
  const empty = await post('/feedback', { body: '   ' });
  assert.equal(empty.status, 422);
  assert.match(await empty.text(), /書いてから/);
  const long = await post('/feedback', { body: 'あ'.repeat(2001) });
  assert.equal(long.status, 422);
  const text = await long.text();
  assert.match(text, /2000/);
  assert.ok(text.includes('あ'.repeat(2001)));
  assert.equal((await log()).length, before);
});

test('設定からご意見への道がある', async () => {
  assert.match(await (await go('/settings')).text(), /href="\/feedback"/);
});
