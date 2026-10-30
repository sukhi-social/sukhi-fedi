// SPDX-License-Identifier: AGPL-3.0-or-later
// 設定の頁。偽の gateway(PATCH update_credentials を覚える)と郵便局を子プロセスで立てて、
// 開く → 保存 → 開き直す、を端から端まで歩く。
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

test('開く: いまの値と、通知のペースが入っている', async () => {
  const res = await go('/settings');
  assert.equal(res.status, 200);
  const page = await res.text();
  assert.match(page, /name="display_name" value="くろ"/);
  assert.match(page, /<textarea name="note"[^>]*>お茶と、古い本。<\/textarea>/);
  assert.match(page, /<select name="hold">/);
  assert.match(page, /name="field_name"/);
});

test('保存: 変えた値が gateway に届き、開き直すと残っている', async () => {
  const fd = new FormData();
  fd.set('display_name', 'くろは');
  fd.set('note', 'お茶と、新しい本。');
  fd.set('location', '縁側');
  fd.set('birthday', '2000-01-02');
  fd.append('field_name', 'blog');
  fd.append('field_value', 'https://blog.example');
  fd.append('field_name', '');
  fd.append('field_value', '');
  fd.set('locked', '1');
  fd.set('hold', '180');
  fd.set('grouping', '1');
  fd.set('avatar', new File([], '')); // 選ばなかった(空)

  const saved = await go('/settings', { method: 'POST', body: fd });
  assert.equal(saved.status, 303);
  assert.equal(saved.headers.get('location'), '/settings');

  const page = await (await go('/settings')).text();
  assert.match(page, /value="くろは"/);
  assert.match(page, /お茶と、新しい本。<\/textarea>/);
  assert.match(page, /name="location" value="縁側"/);
  assert.match(page, /name="birthday" value="2000-01-02"/);
  assert.match(page, /name="field_name" value="blog"/);
  assert.match(page, /name="locked" value="1" checked/);
  assert.doesNotMatch(page, /name="bot" value="1" checked/);
  assert.match(page, /<option value="180" selected>/);
  assert.match(page, /name="grouping" value="1" checked/);
});

test('保存: ほかの設定を外すと、外れる(チェックは「ある・ない」で読む)', async () => {
  const fd = new FormData();
  fd.set('display_name', 'くろは');
  fd.set('hold', '0');
  const saved = await go('/settings', { method: 'POST', body: fd });
  assert.equal(saved.status, 303);
  const page = await (await go('/settings')).text();
  assert.doesNotMatch(page, /name="locked" value="1" checked/);
  assert.doesNotMatch(page, /name="grouping" value="1" checked/);
  assert.match(page, /<option value="0" selected>/);
});

test('保存: 大きすぎる画像は、送らずに入力を残して戻す', async () => {
  const fd = new FormData();
  fd.set('display_name', 'まだ保存しない');
  fd.set('avatar', new File([new Uint8Array(8 * 1024 * 1024 + 1)], 'big.png', { type: 'image/png' }));
  const res = await go('/settings', { method: 'POST', body: fd });
  assert.equal(res.status, 422);
  const page = await res.text();
  assert.match(page, /value="まだ保存しない"/);
  assert.match(page, /class="error"/);
});

test('自分のプロフィールには、設定への道がある', async () => {
  const page = await (await go('/@kuro')).text();
  assert.match(page, /href="\/settings"/);
});
