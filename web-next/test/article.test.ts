// SPDX-License-Identifier: AGPL-3.0-or-later
// 記事(題つきの長い文章)。書く頁に「ひとこと / 記事」があり、記事は題と配りかたを持って gateway へ渡る。
// 開いたとき、題は一度だけ(よその記事は本文の頭に題が折りこまれて届くので、重ならないように外す)。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { withoutTitle } from '../server/views/status.ts';

const PORT = 5204;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4204', PUBLIC_ORIGIN: BASE },
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
const post = (path: string, fields: [string, string][]) => {
  const fd = new FormData();
  for (const [k, v] of fields) fd.append(k, v);
  return go(path, { method: 'POST', body: fd });
};
type Held = { params: { text: string; title: string | null; as_article: boolean | null; spoiler_text: string | null; visibility: string | null; poll: unknown } };
const held = async (): Promise<Held[]> => (await fetch('http://localhost:4204/api/v1/scheduled_statuses')).json();

test('書く頁: 「ひとこと / 記事」があり、ひとことには題の欄がない', async () => {
  const page = await (await go('/compose')).text();
  assert.match(page, /href="\/compose\?kind=article"/);
  assert.match(page, /<a class="tab" href="\/compose" aria-current="true">/);
  assert.doesNotMatch(page, /name="title"/);
  assert.match(page, /name="spoiler_text"/);
});

test('記事の頁: 題・本文・配りかた(記事が既定)。折りたたみと投票は出ない', async () => {
  const page = await (await go('/compose?kind=article')).text();
  assert.match(page, /<a class="tab" href="\/compose\?kind=article" aria-current="true">/);
  assert.match(page, /name="kind" value="article"/);
  assert.match(page, /name="title"[^>]*maxlength="120"[^>]*required/);
  assert.match(page, /name="as_article" value="1" checked/);
  assert.match(page, /name="as_article" value="0" /);
  assert.doesNotMatch(page, /name="as_article" value="0" checked/);
  assert.doesNotMatch(page, /name="spoiler_text"|name="poll_option"/);
  // 指名だけの公開範囲(ふたりの部屋の道)は、記事には出さない。
  assert.doesNotMatch(page, /<option value="direct"/);
  assert.match(page, />記事を出す</);
});

test('返信のなかでは、記事の形にならない', async () => {
  const page = await (await go('/compose?kind=article&reply_to=1001')).text();
  assert.doesNotMatch(page, /name="title"/);
  assert.doesNotMatch(page, /compose\?kind=article/);
});

test('題がなければ、送らずに戻す(書いた本文は残る)', async () => {
  const res = await post('/compose', [['kind', 'article'], ['title', '  '], ['status', '長い話の途中です'], ['as_article', '1']]);
  assert.equal(res.status, 422);
  const page = await res.text();
  assert.match(page, /題を、ひとこと/);
  assert.match(page, /長い話の途中です/);
  assert.match(page, /name="kind" value="article"/);
});

test('題が長すぎれば、送らずに戻す', async () => {
  const res = await post('/compose', [['kind', 'article'], ['title', 'あ'.repeat(121)], ['status', '本文'], ['as_article', '1']]);
  assert.equal(res.status, 422);
  assert.match(await res.text(), /題が長すぎます。120 字まで/);
});

test('記事を出す: 題と配りかたが gateway へ渡り、折りたたみ・投票は渡らない', async () => {
  const res = await post('/compose', [
    ['kind', 'article'], ['title', '  ほうじ茶の日  '], ['status', '## 火のこと\n\n弱いほうが、待てる。'], ['as_article', '1'],
    ['visibility', 'unlisted'], ['spoiler_text', '見せない'], ['poll_option', 'a'], ['poll_option', 'b']
  ]);
  assert.equal(res.status, 303);
  const sent = (await held()).find((h) => h.params.title === 'ほうじ茶の日');
  assert.ok(sent);
  assert.equal(sent.params.as_article, true);
  assert.equal(sent.params.visibility, 'unlisted');
  assert.equal(sent.params.spoiler_text, null);
  assert.equal(sent.params.poll, null);
});

test('「ふつうの投稿として」を選べば、as_article は false で渡る', async () => {
  const res = await post('/compose', [['kind', 'article'], ['title', 'ふつうの題'], ['status', '本文'], ['as_article', '0'], ['visibility', 'public']]);
  assert.equal(res.status, 303);
  const sent = (await held()).find((h) => h.params.title === 'ふつうの題');
  assert.equal(sent?.params.as_article, false);
});

test('記事は指名だけ(direct)にはできない ── 黙って公開に替えず、断る', async () => {
  const before = (await held()).length;
  const res = await post('/compose', [['kind', 'article'], ['title', '題'], ['status', '本文'], ['visibility', 'direct']]);
  assert.equal(res.status, 422);
  assert.equal((await held()).length, before);
});

test('ひとことには、題が渡らない(kind が無ければ、いままで通り)', async () => {
  const res = await post('/compose', [['title', '紛れこんだ題'], ['status', 'ひとことです'], ['visibility', 'public']]);
  assert.equal(res.status, 303);
  const sent = (await held()).find((h) => h.params.text === 'ひとことです');
  assert.ok(sent);
  assert.equal(sent.params.title, null);
  assert.equal(sent.params.as_article, null);
});

test('開いたとき: 自分の記事は、題が見出しとして一度だけ出る', async () => {
  const page = await (await go('/@kuro/2002')).text();
  assert.match(page, /<h1 class="article-title reader-title">ほうじ茶を、はじめて自分で焙じた日<\/h1>/);
  assert.equal(page.split('ほうじ茶を、はじめて自分で焙じた日').length - 1, 2); // <title> と見出し
  assert.match(page, /<h2>火のこと<\/h2>/);
  assert.match(page, /<title>ほうじ茶を、はじめて自分で焙じた日/);
});

test('開いたとき: よその記事は、本文の頭の題(<h2>)を外して、題を一度だけ出す', async () => {
  const page = await (await go('/@hina/2001')).text();
  assert.match(page, /<h1 class="article-title reader-title">板をつくるということ<\/h1>/);
  assert.doesNotMatch(page, /<h2>板をつくるということ<\/h2>/);
  assert.match(page, /掲示板は、タイムライン/);
});

test('withoutTitle: 題と同じ頭の <h2> だけを外す', () => {
  assert.equal(withoutTitle('<h2>題</h2><p>本文</p>', '題'), '<p>本文</p>');
  // エスケープされた題も、同じものとして読む。
  assert.equal(withoutTitle('<h2>A &amp; B</h2><p>x</p>', 'A & B'), '<p>x</p>');
  // 題と違う見出しは、本文の一部。外さない。
  assert.equal(withoutTitle('<h2>火のこと</h2><p>x</p>', '題'), '<h2>火のこと</h2><p>x</p>');
  // 頭にない <h2> も、外さない。
  assert.equal(withoutTitle('<p>先に</p><h2>題</h2>', '題'), '<p>先に</p><h2>題</h2>');
});
