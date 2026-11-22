// SPDX-License-Identifier: AGPL-3.0-or-later
// 私的メモ(プロフィールの、本名の下)。あなただけに見える呼び名。書く・直す・消すが、一つの口を通り、
// gateway の POST /accounts/:id/note に届くこと。偽の gateway と郵便局を子プロセスで立てて歩く。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5242;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4242', PUBLIC_ORIGIN: BASE },
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
const log = async (): Promise<string[]> => (await fetch('http://localhost:4242/__mock/requests-log')).json();
const save = (id: string, comment: string) => {
  const fd = new FormData();
  fd.set('comment', comment);
  return go(`/accounts/${id}/note`, { method: 'POST', body: fd, headers: { 'x-up-target': '#pf-note', 'x-up-version': '3.15.0', referer: `${BASE}/@nabi` } });
};

test('ほかの人の頁には「私的メモを書く」が出る。自分の頁には出ない', async () => {
  const other = await (await go('/@nabi')).text();
  assert.match(other, /id="pf-note"/);
  assert.match(other, /action="\/accounts\/2\/note"/);
  assert.match(other, /私的メモを書く/);
  assert.match(other, /maxlength="2000"/);
  const self = await (await go('/@kuro')).text();
  assert.doesNotMatch(self, /id="pf-note"/);
});

test('書く: gateway に届き、書いたメモが、その場の区画だけで返る', async () => {
  const before = (await log()).length;
  const res = await save('2', '  お隣のパン屋さん  ');
  assert.equal(res.status, 200);
  const frag = await res.text();
  assert.match(frag, /^<div class="account-note" id="pf-note"/);
  assert.match(frag, /account-note-line/);
  assert.match(frag, /お隣のパン屋さん/);
  // 前後の空白は落として送る。
  assert.deepEqual((await log()).slice(before), ['note 2 お隣のパン屋さん']);
});

test('書いたメモは、頁を開きなおしても残り、本名(나비)は上書きされない', async () => {
  const page = await (await go('/@nabi')).text();
  assert.match(page, /account-note-line/);
  assert.match(page, /お隣のパン屋さん/);
  assert.match(page, /나비/);
});

test('HTML は文字のまま(メモの中の < は、こわさない)', async () => {
  const frag = await (await save('2', '<b>x</b> & "q"')).text();
  assert.doesNotMatch(frag, /<b>x<\/b>/);
  assert.match(frag, /&lt;b&gt;x&lt;\/b&gt; &amp; &quot;q&quot;/);
});

test('空にして送ると、メモは消え、「書く」に戻る', async () => {
  const before = (await log()).length;
  const frag = await (await save('2', '   ')).text();
  assert.match(frag, /account-note-add/);
  assert.doesNotMatch(frag, /account-note-line/);
  assert.deepEqual((await log()).slice(before), ['note 2 ']);
});

test('gateway が断ったら(長すぎる)、メモはそのまま。元の頁へ戻して、ひとこと知らせる', async () => {
  await save('2', 'いつもの呼び名');
  const res = await save('2', 'あ'.repeat(2001));
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/@nabi');
  const page = await (await go('/@nabi')).text();
  assert.match(page, /<p class="error" role="status">/);
  assert.match(page, /いつもの呼び名/);
});
