// SPDX-License-Identifier: AGPL-3.0-or-later
// 投票。選んで投票する → 結果の棒(数は目に出さない)。つくる側は、選択肢が二つ以上のときだけ送る。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5202;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4202', PUBLIC_ORIGIN: BASE },
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
const log = async (): Promise<string[]> => (await fetch('http://localhost:4202/__mock/requests-log')).json();
const post = (path: string, fields: [string, string][] = [], headers: Record<string, string> = {}) => {
  const fd = new FormData();
  for (const [k, v] of fields) fd.append(k, v);
  return go(path, { method: 'POST', body: fd, headers });
};

test('入っている人には、選ぶ形(ラジオ)と「投票する」が出る', async () => {
  const page = await (await go('/')).text();
  assert.match(page, /<form class="poll" id="poll-p1"[^>]*action="\/polls\/p1\/vote"/);
  assert.match(page, /type="radio" name="choice" value="0"/);
});

test('投票: gateway に届き、結果の棒だけが返る(数は目に出ない)', async () => {
  const before = (await log()).length;
  const res = await post('/polls/p1/vote', [['choice', '1']], { 'x-up-target': '#poll-p1', 'x-up-version': '3.15.0' });
  assert.equal(res.status, 200);
  const frag = await res.text();
  assert.match(frag, /id="poll-p1"/);
  assert.match(frag, /class="poll-result mine"/);
  assert.doesNotMatch(frag, /<form/);
  assert.doesNotMatch(frag, /class="poll-pct"/);
  assert.deepEqual((await log()).slice(before), ['polls/p1/votes']);
});

test('投票: 選ばずに送ったら、何も送らない', async () => {
  const before = (await log()).length;
  const res = await post('/polls/p1/vote', []);
  assert.equal(res.status, 303);
  assert.equal((await log()).length, before);
});

test('つくる: 書く頁に投票の欄があり、選択肢が一つだけなら送らずに戻す', async () => {
  const page = await (await go('/compose')).text();
  assert.match(page, /name="poll_option"/);
  const res = await post('/compose', [['status', 'どれが好き？'], ['poll_option', 'お茶'], ['poll_option', ''], ['poll_expires', '86400']]);
  assert.equal(res.status, 422);
  assert.match(await res.text(), /二つ以上/);
});

test('つくる: 二つ以上なら、投票つきで送る(お預かりに入る)', async () => {
  const res = await post('/compose', [['status', 'どれが好き？'], ['poll_option', 'お茶'], ['poll_option', 'コーヒー'], ['poll_expires', '3600'], ['visibility', 'public']]);
  assert.equal(res.status, 303);
  const held: { params: { text: string; poll: unknown } }[] = await (await fetch('http://localhost:4202/api/v1/scheduled_statuses')).json();
  const sent = held.find((h) => h.params.text === 'どれが好き？');
  assert.deepEqual(sent?.params.poll, { options: ['お茶', 'コーヒー'], expires_in: 3600, multiple: false });
});
