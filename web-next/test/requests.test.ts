// SPDX-License-Identifier: AGPL-3.0-or-later
// フォロー申請。通知の行のボタンと /requests の一覧が、同じ答えの口を通り、gateway の
// authorize / reject に届くこと。偽の gateway と郵便局を子プロセスで立てて歩く。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5195;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4195', PUBLIC_ORIGIN: BASE },
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
const log = async (): Promise<string[]> => (await fetch('http://localhost:4195/__mock/requests-log')).json();
const post = (path: string, fields: Record<string, string> = {}, up = false) => {
  const fd = new FormData();
  for (const [k, v] of Object.entries(fields)) fd.set(k, v);
  return go(path, { method: 'POST', body: fd, headers: up ? { 'x-up-target': '#nf-9005', 'x-up-version': '3.15.0' } : {} });
};

test('通知: フォロー申請の行にだけ、承認と断るのボタンが付く', async () => {
  const page = await (await go('/notifications')).text();
  assert.match(page, /action="\/requests\/\d+\/accept"/);
  assert.match(page, /action="\/requests\/\d+\/decline"/);
  // 申請の行(9005)の中にあり、ほかの種類の行には付かない。
  const rows = page.split('<article class="notif"').slice(1);
  const withButtons = rows.filter((r) => r.includes('/requests/'));
  assert.equal(withButtons.length, 1);
  assert.match(withButtons[0], /id="nf-9005"/);
  assert.match(withButtons[0], /name="nf" value="9005"/);
});

test('一覧: いま待っている申請が並び、同じボタンが付く', async () => {
  const res = await go('/requests');
  assert.equal(res.status, 200);
  const page = await res.text();
  assert.match(page, /id="rq-\d+"/);
  assert.match(page, /action="\/requests\/\d+\/accept"/);
});

test('承認: gateway の authorize に届き、答えた通知は片づく', async () => {
  const before = (await log()).length;
  const res = await post('/requests/2/accept', { nf: '9005' }, true);
  assert.equal(res.status, 200);
  const frag = await res.text();
  assert.match(frag, /id="nf-9005"/);
  assert.match(frag, /お迎えしました/);
  const got = (await log()).slice(before);
  assert.deepEqual(got, ['follow_requests/2/authorize', 'notifications/9005/dismiss']);
});

test('断る: gateway の reject に届く(通知の id が無ければ、片づけは呼ばない)', async () => {
  const before = (await log()).length;
  const res = await post('/requests/2/decline', {}, true);
  assert.equal(res.status, 200);
  assert.match(await res.text(), /id="rq-2"/);
  assert.deepEqual((await log()).slice(before), ['follow_requests/2/reject']);
});

test('知らないことばは、一覧へ戻す(gateway には何も送らない)', async () => {
  const before = (await log()).length;
  const res = await post('/requests/2/whatever');
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/requests');
  assert.equal((await log()).length, before);
});
