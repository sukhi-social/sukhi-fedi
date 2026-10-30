// SPDX-License-Identifier: AGPL-3.0-or-later
// 関所(/check)。ログインも加入も、一段目のあとで /check を経由し、そこで初めて OAuth が始まる・
// アカウントが作られる。anubis が PoW を解かせるのは、この GET /check だけ。
// 偽の gateway と郵便局を子プロセスで立てて、手順を端から端まで歩く(sessions.json は data/ に出る)。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5197;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: {
      ...process.env,
      SUKHI_DEV_TOKEN: '',
      QUIET: '1',
      PORT: String(PORT),
      MOCK_PORT: '4197',
      PUBLIC_ORIGIN: BASE
    },
    stdio: 'ignore'
  });
  for (let i = 0; i < 50; i++) {
    try {
      if ((await fetch(`${BASE}/login`)).ok) return;
    } catch {
      // まだ立っていない。
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('web-next did not start');
});

after(() => child?.kill());

// cookie を一つだけ持ち回る小さなブラウザ。redirect は自分で辿る。
function browser() {
  let sid = '';
  return async (path: string, init: RequestInit = {}) => {
    const res = await fetch(`${BASE}${path}`, {
      redirect: 'manual',
      ...init,
      headers: { ...(sid ? { cookie: sid } : {}), origin: BASE, ...init.headers }
    });
    const set = res.headers.get('set-cookie')?.split(';')[0];
    if (set) sid = set;
    return res;
  };
}
const form = (body: Record<string, string>): RequestInit => ({
  method: 'POST',
  headers: { 'content-type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams(body)
});

test('ログイン: 一段目のあとは /check へ。OAuth は /check から、一度だけ', async () => {
  const b = browser();
  const first = await b('/login', form({ method: 'password', username: 'a', password: 'b' }));
  assert.equal(first.headers.get('location'), '/check?intent=login');

  const passed = await b('/check?intent=login');
  assert.match(passed.headers.get('location') ?? '', /^\/oauth\/authorize\?/);

  const again = await b('/check?intent=login');
  assert.equal(again.headers.get('location'), '/login');
});

test('加入: コードの確認のあとは /check へ。アカウントは /check から、一度だけ', async () => {
  const b = browser();
  const confirmed = await b(
    '/signup',
    form({ step: 'confirm', username: 'shiro', email: 'a@b.c', agree: '1', code: '123456' })
  );
  assert.equal(confirmed.headers.get('location'), '/check?intent=signup');

  const passed = await b('/check?intent=signup');
  assert.equal(passed.headers.get('location'), '/');

  const again = await b('/check?intent=signup');
  assert.equal(again.headers.get('location'), '/signup');
});

test('何も始まっていない人や、行き先の違う人が /check に来ても、何も始まらない', async () => {
  const none = await browser()('/check?intent=login');
  assert.equal(none.headers.get('location'), '/login');

  const b = browser();
  await b('/login', form({ method: 'password', username: 'a', password: 'b' }));
  const wrong = await b('/check?intent=signup');
  assert.equal(wrong.headers.get('location'), '/signup');
});
