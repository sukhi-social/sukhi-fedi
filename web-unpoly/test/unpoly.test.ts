import { test } from 'node:test';
import assert from 'node:assert/strict';
import { html } from '../server/html.ts';
import { ok, redirect, type Ctx } from '../server/http.ts';
import { backOr } from '../server/routes/shared.ts';

function mockCtx(isUp: boolean, referer?: string, upTarget?: string): Ctx {
  return {
    req: {
      headers: {
        ...(referer ? { referer } : {}),
        ...(isUp ? { 'x-up-version': '3.15.0' } : {}),
        ...(upTarget ? { 'x-up-target': upTarget } : {}),
        host: 'localhost:5174'
      }
    } as any,
    url: new URL('http://localhost:5174/timeline'),
    method: 'POST',
    params: {},
    locale: 'ja',
    t: (k: string) => k,
    isUp,
    upTarget,
    session: undefined,
    cookies: [],
    sess: () => ({} as any),
    me: async () => null,
    form: async () => new FormData(),
    flash: () => {},
    takeFlash: () => undefined,
    setCookie: () => {}
  };
}

test('ok() はカスタムヘッダー(X-Up-Titleなど)を付与できる', () => {
  const res = ok('<p>ok</p>', 200, { 'x-up-title': '新着投稿' });
  assert.equal(res.status, 200);
  assert.equal(res.headers['x-up-title'], '新着投稿');
  assert.equal(res.headers['content-type'], 'text/html; charset=utf-8');
});

test('backOr: Unpoly からの要求なら断片を返す', () => {
  const ctx = mockCtx(true);
  const fragment = html`<article class="status">updated</article>`;
  const res = backOr(ctx, fragment);
  assert.equal(res.status, 200);
  assert.equal(res.body, '<article class="status">updated</article>');
});

test('backOr: ふつうの要求なら referer へ 303 で戻す', () => {
  const ctx = mockCtx(false, 'http://localhost:5174/@alice/123');
  const fragment = html`<article class="status">updated</article>`;
  const res = backOr(ctx, fragment);
  assert.equal(res.status, 303);
  assert.equal(res.headers.location, '/@alice/123');
});
