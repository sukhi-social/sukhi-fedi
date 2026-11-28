// SPDX-License-Identifier: AGPL-3.0-or-later
import { afterEach, expect, test, vi } from 'vitest';
import { ago, evidenceText, parse, receiptText, until } from '../src/format.js';
import { ApiError, applications, sayError, suspensions } from '../src/api.js';

afterEach(() => vi.unstubAllGlobals());

test('parse: 道具の頁は hash から。知らない hash は窓口', () => {
  expect(parse('')).toEqual({ name: 'public' });
  expect(parse('#/applications')).toEqual({ name: 'list' });
  expect(parse('#/applications/482913')).toEqual({ name: 'read', receipt: '482913' });
  expect(parse('#/applications/a/b')).toEqual({ name: 'public' });
});

test('receiptText と ago', () => {
  expect(receiptText('482913')).toBe('482 913');
  const now = new Date('2026-11-23T12:00:00Z');
  expect(ago('2026-11-23T01:00:00Z', now)).toBe('きょう');
  expect(ago('2026-11-22T01:00:00Z', now)).toBe('きのう');
  expect(ago('2026-11-20T01:00:00Z', now)).toBe('3日前');
});

test('管理の口には Bearer を付け、受付番号は符号化して送る', async () => {
  const f = vi.fn(async () => new Response(JSON.stringify({ state: 'welcomed' }), { status: 200 }));
  vi.stubGlobal('fetch', f);
  vi.stubGlobal('sessionStorage', { getItem: () => 'tok', setItem() {}, removeItem() {} });
  await applications.welcome('48/2', 'ひとこと');
  const [url, init] = f.mock.calls[0];
  expect(url).toBe('/api/admin/join_applications/48%2F2/welcome');
  expect(init.headers.authorization).toBe('Bearer tok');
  expect(JSON.parse(init.body)).toEqual({ note: 'ひとこと' });
});

test('失敗は ApiError(status・error)で、ことばに言い直せる', async () => {
  vi.stubGlobal('fetch', async () => new Response(JSON.stringify({ error: 'send_failed' }), { status: 502 }));
  const e = await applications.list().catch((x) => x);
  expect(e).toBeInstanceOf(ApiError);
  expect(e.status).toBe(502);
  expect(sayError(e)).toMatch(/メールが出ませんでした/);
  vi.stubGlobal('fetch', async () => { throw new TypeError('x'); });
  expect((await applications.list().catch((x) => x)).code).toBe('network');
});

test('login: challenge は verifier の SHA-256(RFC 7636 の例)', async () => {
  const { challengeOf, randomString } = await import('../src/login.js');
  expect(await challengeOf('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk')).toBe('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  expect(randomString()).toMatch(/^[A-Za-z0-9_-]{43}$/);
});

test('login: 戻りの state が違えば、トークンに替えない', async () => {
  const store = { 'gov.state': 'S', 'gov.verifier': 'V' };
  vi.stubGlobal('sessionStorage', {
    getItem: (k) => store[k] ?? null,
    setItem: (k, v) => (store[k] = v),
    removeItem: (k) => delete store[k]
  });
  vi.stubGlobal('history', { replaceState() {} });
  vi.stubGlobal('location', { origin: 'https://gov.test', pathname: '/', hash: '' });
  const { finish } = await import('../src/login.js');
  const f = vi.fn();
  expect(await finish('?code=c&state=X', f)).toBe(false);
  expect(f).not.toHaveBeenCalled();
  expect(store['gov.verifier']).toBeUndefined();
});

test('login: 正しい戻りは verifier だけで引き換え(secret なし)、トークンを置く', async () => {
  const store = { 'gov.state': 'S', 'gov.verifier': 'V' };
  vi.stubGlobal('sessionStorage', {
    getItem: (k) => store[k] ?? null,
    setItem: (k, v) => (store[k] = v),
    removeItem: (k) => delete store[k]
  });
  vi.stubGlobal('history', { replaceState() {} });
  vi.stubGlobal('location', { origin: 'https://gov.test', pathname: '/', hash: '' });
  const { finish } = await import('../src/login.js');
  const f = vi.fn(async () => new Response(JSON.stringify({ access_token: 'T' }), { status: 200 }));
  expect(await finish('?code=c&state=S', f)).toBe(true);
  const body = JSON.parse(f.mock.calls[0][1].body);
  expect(body).toMatchObject({ grant_type: 'authorization_code', code: 'c', code_verifier: 'V', redirect_uri: 'https://gov.test/' });
  expect(body.client_secret).toBeUndefined();
  expect(store['gov.token'] ?? Object.values(store).includes('T')).toBeTruthy();
  expect(await finish('', f)).toBe(null);
});

test('お休みの頁: hash から。あと何か・確かめの言い方', () => {
  expect(parse('#/suspensions')).toEqual({ name: 'suspensions' });
  const now = new Date('2026-11-28T09:00:00Z');
  expect(until('2026-11-28T09:30:00Z', now)).toBe('あと30分');
  expect(until('2026-11-28T12:10:00Z', now)).toBe('あと3時間');
  expect(until('2026-11-30T12:00:00Z', now)).toBe('あと2日');
  expect(until('2026-11-28T08:59:00Z', now)).toBe('終わっています');
  expect(until(null, now)).toBe('');
  expect(evidenceText(null)).toBe('まだ確かめていません');
  expect(evidenceText({ failure: 'unlinked' })).toMatch(/つながりが見つかりません/);
  expect(evidenceText({ failure: null, verified_at: '2026-11-28T09:00:00Z' })).toMatch(/^確かめました/);
});

test('無視する・やめるは、id を本文で(URL なのでパスに入れない)', async () => {
  const f = vi.fn(async () => new Response(JSON.stringify({ ignored: true }), { status: 200 }));
  vi.stubGlobal('fetch', f);
  vi.stubGlobal('sessionStorage', { getItem: () => 'tok', setItem() {}, removeItem() {} });
  await suspensions.ignore('https://rest.example/suspensions/1');
  let [url, init] = f.mock.calls[0];
  expect(url).toBe('/api/admin/delivery_suspensions/ignore');
  expect(init.method).toBe('POST');
  expect(init.headers.authorization).toBe('Bearer tok');
  expect(JSON.parse(init.body)).toEqual({ id: 'https://rest.example/suspensions/1' });
  await suspensions.unignore('n');
  [url] = f.mock.calls[1];
  expect(url).toBe('/api/admin/delivery_suspensions/unignore');
});

test('お休みがもう無いときは、そっと言う', async () => {
  vi.stubGlobal('fetch', async () => new Response(JSON.stringify({ error: 'suspension_not_found' }), { status: 404 }));
  const e = await suspensions.list().catch((x) => x);
  expect(sayError(e)).toMatch(/記録にありません/);
});
