// SPDX-License-Identifier: AGPL-3.0-or-later
// 書きかけ(ふつうのノート): 置く・戻る・消す・送れたら畳む・戻さない場所・読めないとき。
// 偽の gateway(/api/i/notes/drafts を、状態つきで持つ)と郵便局を子プロセスで立てて、歩く。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { loggedOutServer } from './bell.ts';

const PORT = 5255;
const MOCK = 4255;
const BASE = `http://localhost:${PORT}`;
const M = `http://localhost:${MOCK}/__mock`;
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
// 書く欄の JS が送る形(urlencoded)。
const save = (fields: Record<string, string>, path = '/compose/draft') => go(path, { method: 'POST', body: new URLSearchParams(fields) });
// 頁のフォーム(multipart)。
const compose = (fields: [string, string][]) => {
  const fd = new FormData();
  for (const [k, v] of fields) fd.append(k, v);
  return go('/compose', { method: 'POST', body: fd });
};
const mockPost = (q: string) => fetch(`${M}/draft?${q}`, { method: 'POST' });
const seed = (o: Record<string, string>) => mockPost(new URLSearchParams(o).toString());
const reset = () => mockPost('reset=1');
const log = async (): Promise<string[]> => (await fetch(`${M}/requests-log`)).json();
const drafts = async (since: number) => (await log()).slice(since).filter((l) => l.startsWith('draft '));

const textarea = (page: string) => /<textarea name="status"[^>]*>([^<]*)<\/textarea>/.exec(page)?.[1];

test('はじめて開く: 書きかけは無く、欄は空。「残っていました」は、隠れたまま', async () => {
  await reset();
  const page = await (await go('/compose')).text();
  assert.equal(textarea(page), '');
  assert.match(page, /note: true, restored: false,/);
  assert.match(page, /<p class="composer-reply" x-show="restored" x-cloak>/); // 欄は在るが、見えない
  // ふつうのノートは、手を止めたあとに置く。送りはじめたら、置かない
  assert.match(page, /@input\.debounce\.600ms="saveNote\(\)" @submit="holdSave\(\)"/);
});

test('置く: 書く欄の送りは、gateway の書きかけへ(本文・注意書き・センシティブ・公開範囲)', async () => {
  await reset();
  const before = (await log()).length;
  const res = await save({ status: '夜のメモ', spoiler_text: '注意', sensitive: '1', visibility: 'unlisted' });
  assert.equal(res.status, 204);
  assert.deepEqual(await drafts(before), ['draft PUT {"text":"夜のメモ","spoiler":"注意","useSpoiler":true,"sensitive":true,"visibility":"unlisted"}']);

  // 注意書きなし・センシティブなし・公開範囲なし(公開)
  const b2 = (await log()).length;
  assert.equal((await save({ status: 'ただの一言' })).status, 204);
  assert.deepEqual(await drafts(b2), ['draft PUT {"text":"ただの一言","spoiler":"","useSpoiler":false,"sensitive":false,"visibility":"public"}']);
  await reset();
});

test('置く: 注意書きだけでも置く。本文も注意書きも空なら、置かずに畳む', async () => {
  await reset();
  const before = (await log()).length;
  await save({ status: '   ', spoiler_text: 'あとで書く' });
  await save({ status: ' \n ', spoiler_text: '  ' });
  assert.deepEqual(await drafts(before), ['draft PUT {"text":"   ","spoiler":"あとで書く","useSpoiler":true,"sensitive":false,"visibility":"public"}', 'draft DELETE']);
  await reset();
});

test('置く: 公開範囲が四つのどれでもなければ、gateway が断る ── そのまま返す', async () => {
  await reset();
  assert.equal((await save({ status: 'あ', visibility: 'secret' })).status, 422);
  await reset();
});

test('戻る: 置いてあるものが、書く欄に。本文・注意書き(折りたたみ)・センシティブ・公開範囲。「残っていました」が出る', async () => {
  await reset();
  await seed({ text: '昨夜の続き', spoiler: 'ねむい', sensitive: '1', visibility: 'unlisted' });
  const page = await (await go('/compose')).text();
  assert.equal(textarea(page), '昨夜の続き');
  assert.match(page, /note: true, restored: true,/);
  assert.match(page, /composeAssist\(\{ cw: true,/);
  assert.match(page, /name="spoiler_text" value="ねむい"/);
  assert.match(page, /name="sensitive" value="1" checked/);
  assert.match(page, /<option value="unlisted" selected>/);
  assert.doesNotMatch(page, /<option value="public" selected>/);
  await reset();
});

test('戻る: 置いて、開きなおすと、その続きから(行って帰る)', async () => {
  await reset();
  await save({ status: '行って帰る', visibility: 'private' });
  const page = await (await go('/compose')).text();
  assert.equal(textarea(page), '行って帰る');
  assert.match(page, /<option value="private" selected>/);
  await reset();
});

test('戻さない場所: 返信・引用・記事・共有からの書き出し・失敗して返った頁。gateway にも、訊かない', async () => {
  await reset();
  await seed({ text: '別の書きかけ' });
  const before = (await log()).length;
  for (const path of ['/compose?reply_to=1001', '/compose?quote=1001', '/compose?kind=article', '/compose?text=%E5%85%B1%E6%9C%89%E3%81%95%E3%82%8C%E3%81%9F']) {
    const page = await (await go(path)).text();
    assert.doesNotMatch(page, /別の書きかけ/, path);
    assert.match(page, /restored: false,/, path);
  }
  // 共有の字は、そのまま
  assert.equal(textarea(await (await go('/compose?text=%E5%85%B1%E6%9C%89%E3%81%95%E3%82%8C%E3%81%9F')).text()), '共有された');
  // 失敗して返ってきた頁(空では送れない)は、書いたものが先
  const failed = await compose([['status', ''], ['spoiler_text', '残る注意書き']]);
  assert.equal(failed.status, 422);
  assert.doesNotMatch(await failed.text(), /別の書きかけ/);
  assert.deepEqual(await drafts(before), []); // gateway の書きかけの口には、一度も訊いていない
  await reset();
});

test('消す: 「消す」は、gateway の書きかけを畳む。つぎに開くと、空', async () => {
  await reset();
  await save({ status: '消すもの' });
  const before = (await log()).length;
  const res = await save({}, '/compose/draft/discard');
  assert.equal(res.status, 204);
  assert.deepEqual(await drafts(before), ['draft DELETE']);
  const page = await (await go('/compose')).text();
  assert.equal(textarea(page), '');
  assert.match(page, /restored: false,/);
});

test('送れたら畳む: はじめの一通を送れたら、書きかけは要らない(お預かりでも)', async () => {
  await reset();
  await save({ status: '送るもの' });
  const before = (await log()).length;
  const res = await compose([['status', '送るもの'], ['visibility', 'public']]);
  assert.equal(res.status, 303);
  assert.deepEqual(await drafts(before), ['draft DELETE']);
  assert.equal(textarea(await (await go('/compose')).text()), '');
});

test('送れたら畳む: 返信・引用は、書きかけにふれない。送れなかったときも、畳まない', async () => {
  await reset();
  await save({ status: '手つかずの書きかけ' });
  const before = (await log()).length;
  assert.equal((await compose([['status', '返信です'], ['in_reply_to_id', '1001']])).status, 303);
  assert.equal((await compose([['status', '引用です'], ['quote_id', '1001']])).status, 303);
  assert.equal((await compose([['status', '']])).status, 422); // 空では送れない
  assert.deepEqual(await drafts(before), []);
  assert.equal(textarea(await (await go('/compose')).text()), '手つかずの書きかけ');
  await reset();
});

test('読めないとき: gateway が書きかけを返せなくても、書く頁はいつもどおり開く', async () => {
  await reset();
  await mockPost('fail=1');
  const res = await go('/compose');
  assert.equal(res.status, 200);
  const page = await res.text();
  assert.equal(textarea(page), '');
  assert.match(page, /restored: false,/);
  await reset();
});

test('入っていない人: 置く口も消す口も、頁を追わせず 401', async () => {
  const out = await loggedOutServer(5256);
  try {
    for (const path of ['/compose/draft', '/compose/draft/discard']) {
      const res = await fetch(`${out.base}${path}`, { method: 'POST', redirect: 'manual', body: new URLSearchParams({ status: 'あ' }) });
      assert.equal(res.status, 401, path);
    }
  } finally {
    out.stop();
  }
});
