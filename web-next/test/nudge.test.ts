// SPDX-License-Identifier: AGPL-3.0-or-later
// メールのお願い。確認の済んでいない人にだけ、頁の先頭に、小さなカードがそっと出る。
// 偽の gateway(cookie 専用の口は session_token=mock が要る)と郵便局を子プロセスで立てて、段ごとに歩く。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5244;
const MOCK = 4244;
const BASE = `http://localhost:${PORT}`;
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

// ブラウザの cookie 入れ。新しい人(別のブラウザ)は fresh() で。
let jar: Record<string, string> = {};
const fresh = () => {
  jar = {};
};
const UP = { 'x-up-version': '3.15.0', 'x-up-target': '#email-nudge' };

async function go(path: string, init: RequestInit & { signedIn?: boolean; up?: boolean; form?: Record<string, string> } = {}) {
  const { signedIn = true, up = false, form, ...rest } = init;
  const cookie = [...Object.entries(jar).map(([k, v]) => `${k}=${v}`), signedIn ? 'session_token=mock' : ''].filter(Boolean).join('; ');
  const res = await fetch(`${BASE}${path}`, {
    redirect: 'manual',
    ...rest,
    ...(form ? { method: 'POST', body: new URLSearchParams(form) } : {}),
    headers: { ...(cookie ? { cookie } : {}), origin: BASE, ...(form ? { 'content-type': 'application/x-www-form-urlencoded' } : {}), ...(up ? UP : {}), ...rest.headers }
  });
  for (const c of res.headers.getSetCookie()) {
    const [pair] = c.split(';');
    const i = pair.indexOf('=');
    jar[pair.slice(0, i)] = pair.slice(i + 1);
  }
  return res;
}
const text = async (path: string, init?: Parameters<typeof go>[1]) => (await go(path, init)).text();
const post = (path: string, form: Record<string, string>, init: Parameters<typeof go>[1] = {}) => go(path, { up: true, ...init, form });
const mock = (q: string) => fetch(`http://localhost:${MOCK}/__mock/email?${q}`, { method: 'POST' });
const log = async (): Promise<string[]> => (await fetch(`http://localhost:${MOCK}/__mock/requests-log`)).json();
const EMPTY = '<div id="email-nudge"></div>';
const SLOT = /<div id="email-nudge" up-defer up-href="\/nudge"><\/div>/;

test('確認の済んだ人: 置き場は一度だけ。聞いて済んでいるとわかったら、もう置かない', async () => {
  fresh();
  await mock('verified=1&address=kuro@example.com');
  assert.match(await text('/settings'), SLOT);
  assert.equal(await text('/nudge', { up: true }), EMPTY);
  assert.doesNotMatch(await text('/settings'), /email-nudge/);
});

test('置き場から来る以外(アドレスを直に開いた)は、ホームへ戻す', async () => {
  fresh();
  const res = await go('/nudge');
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/');
});

test('未登録の人: 流れの中にカード。入力欄は空で、「あとで」はそこから押せる', async () => {
  fresh();
  await mock('verified=0&address=none');
  const card = await text('/nudge', { up: true });
  assert.match(card, /<div id="email-nudge"><!--email_off--><aside class="email-nudge"/);
  assert.match(card, /もしものとき/);
  assert.match(card, /action="\/nudge\/send"/);
  assert.match(card, /<input type="email" name="email" value=""/);
  assert.match(card, /formaction="\/nudge\/later"/);
});

test('未確認の人: 登録したアドレスが入力欄に入っている。言いかたも変わる', async () => {
  fresh();
  await mock('verified=0&address=kuro@example.com');
  const card = await text('/nudge', { up: true });
  assert.match(card, /確認が、まだ済んでいません/);
  assert.match(card, /<input type="email" name="email" value="kuro@example\.com"/);
});

test('cookie の無い人: 入力欄の代わりに「入りなおして」。「あとで」は残る', async () => {
  fresh();
  await mock('verified=0&address=none');
  const card = await text('/nudge', { up: true, signedIn: false });
  assert.match(card, /href="\/login"/);
  assert.doesNotMatch(card, /action="\/nudge\/send"/);
  assert.match(card, /action="\/nudge\/later"/);
});

test('コードを送る: 形のちがう・使われている・回数制限は、カードの中でやさしく断る', async () => {
  fresh();
  await mock('verified=0&address=none');
  const bad = await (await post('/nudge/send', { email: 'nope' })).text();
  assert.match(bad, /形が、ちがうみたいです/);
  assert.match(bad, /<input type="email" name="email" value="nope"/); // 打った字は残す
  assert.match(await (await post('/nudge/send', { email: 'taken@example.com' })).text(), /もう使われています/);
  assert.match(await (await post('/nudge/send', { email: 'limit@example.com' })).text(), /すこし間をおいて/);
  assert.equal((await log()).filter((l) => l.startsWith('email/request')).length, 0);
});

test('コードを送って、合わなければ残り、合えば「ありがとう」。そのあとは置き場も出ない', async () => {
  fresh();
  await mock('verified=0&address=none');
  const sent = await (await post('/nudge/send', { email: 'new@example.com' })).text();
  assert.match(sent, /action="\/nudge\/confirm"/);
  assert.match(sent, /<input type="hidden" name="email" value="new@example\.com"/);
  assert.match(sent, /コードを送りました/);
  assert.match(sent, /formaction="\/nudge\/send"/); // もう一度送る
  assert.ok((await log()).includes('email/request new@example.com'));

  const wrong = await (await post('/nudge/confirm', { email: 'new@example.com', code: '000000' })).text();
  assert.match(wrong, /コードが、合いませんでした/);
  assert.match(wrong, /action="\/nudge\/confirm"/);
  assert.match(await text('/settings'), SLOT); // まだ済んでいない

  const done = await (await post('/nudge/confirm', { email: 'new@example.com', code: '123456' })).text();
  assert.match(done, /ありがとう/);
  assert.match(done, /@click="open = false"/); // 閉じるは、その場で畳むだけ
  assert.doesNotMatch(await text('/settings'), /email-nudge/);
});

test('あとで: 3 日静か(cookie)。静かな間は、置き場も出ず、カードも返らない', async () => {
  fresh();
  await mock('verified=0&address=none');
  const res = await post('/nudge/later', {});
  assert.equal(await res.text(), EMPTY);
  assert.match(jar.sukhi_nudge, /^\d+\.1$/);
  const until = Number(jar.sukhi_nudge.split('.')[0]);
  assert.ok(Math.abs(until - (Date.now() + 3 * 86400000)) < 60_000);
  assert.doesNotMatch(await text('/settings'), /email-nudge/);
  assert.equal(await text('/nudge', { up: true }), EMPTY);
});

test('二度目の「あとで」: もっと静かにする選び口が出る。選ぶと 30 日、押した回数は残る', async () => {
  fresh();
  await mock('verified=0&address=none');
  jar.sukhi_nudge = `${Date.now() - 1000}.1`; // 一度目の静けさは、もう明けている
  const second = await (await post('/nudge/later', {})).text();
  assert.match(second, /3 日たったら/);
  assert.match(second, /action="\/nudge\/quiet"/);
  assert.match(second, /@click="open = false"/); // 「3 日後でいい」
  assert.match(jar.sukhi_nudge, /\.2$/);

  assert.equal(await (await post('/nudge/quiet', {})).text(), EMPTY);
  const [until, count] = jar.sukhi_nudge.split('.').map(Number);
  assert.equal(count, 2);
  assert.ok(Math.abs(until - (Date.now() + 30 * 86400000)) < 60_000);
});

test('こわれた cookie は、静かにしていない扱い(落ちない)', async () => {
  fresh();
  await mock('verified=0&address=none');
  jar.sukhi_nudge = 'abc';
  assert.match(await text('/settings'), SLOT);
  jar.sukhi_nudge = '99999999999999999999.1';
  assert.match(await text('/settings'), SLOT);
});

test('ログインと安全の頁には置かない(そこに居る人には、言うまでもない)', async () => {
  fresh();
  await mock('verified=0&address=none');
  assert.match(await text('/settings'), SLOT);
  assert.doesNotMatch(await text('/settings/security'), /email-nudge/);
});

test('JS の無いブラウザでの「あとで」は、元の頁へ戻す(静けさは、同じように覚える)', async () => {
  fresh();
  const res = await go('/nudge/later', { form: {}, headers: { referer: `${BASE}/settings` } });
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/settings');
  assert.match(jar.sukhi_nudge, /\.1$/);
});
