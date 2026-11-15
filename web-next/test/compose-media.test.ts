// SPDX-License-Identifier: AGPL-3.0-or-later
// 投稿に画像をつける道(サーバー側)。alt は画像と同じ順で組になって gateway へ「description」として届く。
// 画像だけでも、本文が空でも、投稿できる(記事は別)。四枚まで。
// (ブラウザで整える・貼る・切るところは、public/js/media.js ── 実機で歩く。純粋なところは test/media.test.ts。)
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5205;
const BASE = `http://localhost:${PORT}`;
const MOCK = 'http://localhost:4205';
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4205', PUBLIC_ORIGIN: BASE },
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
const log = async (): Promise<string[]> => (await fetch(`${MOCK}/__mock/requests-log`)).json();
const held = async (): Promise<{ params: { text: string; media_ids: string[] | null } }[]> => (await fetch(`${MOCK}/api/v1/scheduled_statuses`)).json();

// 中身のある、ちいさな「画像」(サーバーは中身を見ない。mock は大きさと名前だけ受け取る)。
const png = (name: string, bytes = 8) => new File([new Uint8Array(bytes).fill(1)], name, { type: 'image/png' });
const compose = (status: string, files: [File, string][], extra: [string, string][] = []) => {
  const fd = new FormData();
  fd.append('status', status);
  fd.append('visibility', 'public');
  for (const [k, v] of extra) fd.append(k, v);
  // 画面は、画像ごとに alt の欄を一つ持つので、同じ順で並んで届く。
  for (const [file, alt] of files) {
    fd.append('files', file);
    fd.append('alt', alt);
  }
  return go('/compose', { method: 'POST', body: fd });
};

test('書く頁: 貼れる・落とせる仕組みと、画像のカードが載っている', async () => {
  const page = await (await go('/compose')).text();
  assert.match(page, /@paste\.document="onPaste\(\$event\)"/);
  assert.match(page, /x-ref="files"/);
  assert.match(page, /name="alt"/);
  assert.match(page, /:disabled="notReady\(\)"/);
  assert.match(page, /type="module" src="\/assets\/js\/media\.js\?v=/);
});

test('alt は、画像と同じ順で description になって届く。投稿は media_ids を持つ', async () => {
  const before = (await log()).length;
  const res = await compose('朝のお茶', [[png('one.png', 11), 'ひとつめ'], [png('two.png', 22), ''], [png('three.png', 33), 'みっつめ']]);
  assert.equal(res.status, 303);
  assert.deepEqual((await log()).slice(before), ['media one.png 11 ひとつめ', 'media two.png 22 ', 'media three.png 33 みっつめ']);
  const sent = (await held()).find((h) => h.params.text === '朝のお茶');
  assert.equal(sent?.params.media_ids?.length, 3);
});

test('画像だけでも、本文が空でも、投稿できる', async () => {
  const res = await compose('', [[png('only.png', 5), 'ことばなし']]);
  assert.equal(res.status, 303);
  const sent = (await held()).find((h) => h.params.text === '' && h.params.media_ids?.length === 1);
  assert.ok(sent, 'お預かりに、画像だけの投稿が入る');
});

test('本文も画像も空なら、これまでどおり戻す。記事は、画像だけでは通さない', async () => {
  assert.equal((await compose('', [])).status, 422);
  const res = await compose('', [[png('a.png'), '']], [['kind', 'article'], ['title', '題']]);
  assert.equal(res.status, 422);
});

test('五枚目は、黙って足さない(四枚まで)', async () => {
  const before = (await log()).length;
  const res = await compose('たくさん', Array.from({ length: 5 }, (_, i): [File, string] => [png(`n${i}.png`, 3), `alt${i}`]));
  assert.equal(res.status, 303);
  assert.deepEqual(
    (await log()).slice(before).map((l) => l.split(' ')[1]),
    ['n0.png', 'n1.png', 'n2.png', 'n3.png']
  );
});

test('空の欄(0 バイト)を飛ばしても、alt がずれない', async () => {
  const before = (await log()).length;
  // 画像を選ばずに送ると、空のファイルが一つ届く。そのとき alt の欄は無い。もう一つ試すのは、空のあとに画像が来る形。
  const fd = new FormData();
  fd.append('status', 'ずれない');
  fd.append('files', new File([], ''));
  fd.append('alt', '空のぶん');
  fd.append('files', png('real.png', 9));
  fd.append('alt', 'ほんとうの alt');
  const res = await go('/compose', { method: 'POST', body: fd });
  assert.equal(res.status, 303);
  assert.deepEqual((await log()).slice(before), ['media real.png 9 ほんとうの alt']);
});
