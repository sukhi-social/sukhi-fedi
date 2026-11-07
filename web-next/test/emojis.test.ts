// SPDX-License-Identifier: AGPL-3.0-or-later
// 絵文字の選び口(リアクション)と、書く欄の絵文字・@ の候補。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5203;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4203', PUBLIC_ORIGIN: BASE },
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
const text = async (path: string) => (await go(path)).text();

test('カードの「…」に「リアクションをつける」があり、下に空の置き場がある', async () => {
  const page = await text('/');
  assert.match(page, /href="\/statuses\/1001\/react\?d=st-1001"[^>]*up-target="#rp-st-1001"/);
  assert.match(page, /<div id="rp-st-1001"><\/div>/);
});

test('選び口: カスタム絵文字が分けて並び、押すと :shortcode: で react に送る形', async () => {
  const frag = await text('/statuses/1001/react?d=st-1001');
  assert.match(frag, /^<div id="rp-st-1001" class="emoji-picker"/);
  assert.match(frag, /くらし/);
  assert.match(frag, /action="\/statuses\/1001\/react"/);
  assert.match(frag, /name="emoji" value=":tea:"/);
  assert.match(frag, /name="on" value="1"/);
});

test('選び口: たたむと、空の置き場に戻る。id に変なものは通さない', async () => {
  assert.equal(await text('/statuses/1001/react?close=1&d=st-1001'), '<div id="rp-st-1001"></div>');
  const odd = await text('/statuses/1001/react?close=1&d=%22%3E%3Cx');
  assert.equal(odd, '<div id="rp-st-1001"></div>');
});

test('書く欄: 絵文字の列と、@ の候補を受ける枠がある', async () => {
  const page = await text('/compose');
  assert.match(page, /x-data="composeAssist\(/);
  assert.match(page, /@click="ins\(':tea:'\)"/);
  assert.match(page, /x-html="hits"/);
});

test('@ の候補: 名前と acct だけの小さな一覧(押したときに入る)。空の問いは空', async () => {
  const frag = await text('/people/suggest?q=na');
  assert.match(frag, /<ul class="suggest"/);
  assert.match(frag, /data-acct="nabi"/);
  assert.equal(await text('/people/suggest?q='), '');
});
