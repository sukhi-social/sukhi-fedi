// SPDX-License-Identifier: AGPL-3.0-or-later
// 投稿の翻訳。前半は、ことばの見当・ボタンを出すかどうかの、手元の決めごと(純粋)。
// 後半は、偽の gateway と郵便局を子プロセスで立てて、押す → 原文の下に訳が足される、を端から端まで。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { baseLang, guessLang, offerFor, plainText, prefsOf } from '../server/translate.ts';
import type { Account, Status } from '../server/types.ts';

const me = { id: '1', acct: 'kuro', source: {} } as unknown as Account;
const post = (content: string, extra: Partial<Status> = {}): Status =>
  ({ id: '9', content, visibility: 'public', account: { id: '2', acct: 'x' }, ...extra }) as unknown as Status;

test('guessLang: 字の種類で、かな→ja、ハングル→ko、ラテン→en', () => {
  assert.equal(guessLang('<p>今日は雨でした。</p>').lang, 'ja');
  assert.equal(guessLang('<p>오늘은 비가 와서 집에 있었어요.</p>').lang, 'ko');
  assert.equal(guessLang('<p>Finally finished the scarf.</p>').lang, 'en');
  assert.equal(guessLang('<p>Привет, как дела?</p>').lang, 'ru');
});

test('guessLang: 漢字だけは決めない(null)。URL・メンション・タグ・絵文字コードは数えない', () => {
  assert.equal(guessLang('<p>今日天気很好</p>').lang, null);
  assert.equal(guessLang('<p>https://example.com/ハングル @안녕 #タグ :blobcat:</p>').letters, 0);
  assert.equal(plainText('<p>a<br>b &amp; c</p>'), 'a b & c');
});

test('baseLang: 地域の印を落とす', () => {
  assert.equal(baseLang('ja-JP'), 'ja');
  assert.equal(baseLang('zh_CN'), 'zh');
  assert.equal(baseLang('KO'), 'ko');
  assert.equal(baseLang('x'), null);
  assert.equal(baseLang(null), null);
});

test('prefsOf: 何も選んでいなければ、画面のことばだけを読める', () => {
  const p = prefsOf(me, 'ko');
  assert.deepEqual(p.reads, ['ko']);
  assert.equal(p.target, 'ko');
  assert.equal(p.engine, 'libre');
  const q = prefsOf({ ...me, source: { translate_reads: ['fr', 'en-US'], translate_engine: 'deepl', translate_deepl_key_hint: 'abcd' } } as Account, 'ja');
  assert.deepEqual(q.reads, ['fr', 'en']);
  assert.equal(q.target, 'en'); // 読めることばの先頭の、訳せるもの
  assert.equal(q.hasKey, true);
});

test('offerFor: 読めないことばの投稿にだけ、押せるボタンが出る', () => {
  const prefs = prefsOf(me, 'ja');
  assert.equal(offerFor(post('<p>오늘은 비가 와서 집에 있었어요.</p>'), me, prefs, true), 'ask');
  assert.equal(offerFor(post('<p>毛糸を買いに行った。</p>'), me, prefs, true), 'none'); // 読める
  assert.equal(offerFor(post('<p>오늘은 비가 와요.</p>'), me, prefs, false), 'none'); // 訳し役がいない
  assert.equal(offerFor(post('<p>오늘은 비가 와요.</p>'), null, prefs, true), 'none'); // 入っていない
  assert.equal(offerFor(post('<p>오늘은 비가 와요.</p>', { visibility: 'direct' }), me, prefs, true), 'none'); // DM
  assert.equal(offerFor(post('<p>오늘은 비가 와요.</p>', { account: { id: '1' } as Account }), me, prefs, true), 'none'); // 自分の
  assert.equal(offerFor(post('<p>🍵</p>'), me, prefs, true), 'none'); // 訳す字がない
});

test('offerFor: 名乗っていることば(language)を先に信じる。学んでいることばは learn', () => {
  const learner = prefsOf({ ...me, source: { translate_learns: ['ko'] } } as Account, 'ja');
  assert.equal(offerFor(post('<p>오늘은 비가 와서 집에 있었어요.</p>'), me, learner, true), 'learn');
  assert.equal(offerFor(post('<p>Hello there friend</p>', { language: 'ja' }), me, learner, true), 'none'); // ja と名乗っている
  assert.equal(offerFor(post('<p>今日天気很好</p>'), me, learner, true), 'ask'); // 見当がつかない → 出す
});

// ── 端から端まで ───────────────────────────────────────────────
const PORT = 5194;
const BASE = `http://localhost:${PORT}`;
const MOCK = `http://localhost:4194`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4194', PUBLIC_ORIGIN: BASE },
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
const up = { 'x-up-version': '3', 'x-up-target': '#tr-st-1002-body' };
const form = (o: Record<string, string>) => new URLSearchParams(o);

test('ホーム: 読めないことば(ko)の投稿にだけ「訳を見る」が出て、訳はまだ出ない', async () => {
  const page = await (await go('/')).text();
  const ko = page.slice(page.indexOf('id="st-1002"'), page.indexOf('id="st-1003"'));
  assert.match(ko, /id="tr-st-1002"/);
  assert.match(ko, /action="\/statuses\/1002\/translate"/);
  assert.match(ko, /訳を見る/);
  assert.doesNotMatch(ko, /class="tr-box"/);
  // 日本語の投稿には出ない。
  const ja = page.slice(page.indexOf('id="st-1003"'), page.indexOf('id="st-1004"'));
  assert.doesNotMatch(ja, /tr-slot/);
});

test('押す: 原文の下に、エンジン名つきの訳が足される(Unpoly なら、訳の場所だけ)', async () => {
  const res = await go('/statuses/1002/translate', {
    method: 'POST',
    headers: { ...up, 'content-type': 'application/x-www-form-urlencoded' },
    body: form({ dom: 'st-1002' })
  });
  assert.equal(res.status, 200);
  const frag = await res.text();
  assert.match(frag, /id="tr-st-1002-body"/);
  assert.match(frag, /class="tr-box"[^>]*translate="no"[^>]*lang="ja"/);
  assert.match(frag, /訳\(機械翻訳\)/);
  assert.match(frag, /LibreTranslate/);
  assert.match(frag, /影島でコーヒー/);
  assert.match(frag, /とじる/);
});

test('混んでいるとき: 責めずに、理由と次の一手。自動では再試行しない', async () => {
  await fetch(`${MOCK}/__mock/translate?fail=busy`, { method: 'POST' });
  const res = await go('/statuses/1002/translate', {
    method: 'POST',
    headers: { ...up, 'content-type': 'application/x-www-form-urlencoded' },
    body: form({ dom: 'st-1002' })
  });
  const frag = await res.text();
  assert.match(frag, /いま、訳し役が混んでいます/);
  assert.match(frag, /原文は、このまま読めます/);
  assert.match(frag, /action="\/statuses\/1002\/translate"/); // もう一度押せる
  await fetch(`${MOCK}/__mock/translate`, { method: 'POST' });
});

test('キーの理由は、設定への道つきで返る', async () => {
  await fetch(`${MOCK}/__mock/translate?fail=key_rejected`, { method: 'POST' });
  const frag = await (
    await go('/statuses/1002/translate', {
      method: 'POST',
      headers: { ...up, 'content-type': 'application/x-www-form-urlencoded' },
      body: form({ dom: 'st-1002' })
    })
  ).text();
  assert.match(frag, /DeepL がキーを受けつけませんでした/);
  assert.match(frag, /href="\/settings\/translation"/);
  await fetch(`${MOCK}/__mock/translate`, { method: 'POST' });
});

test('設定: 開く → DeepL のキーなしで保存は断る → 読めることば・学ぶことば・キーを保存', async () => {
  const page = await (await go('/settings/translation')).text();
  assert.match(page, /name="reads" value="ja"/);
  assert.match(page, /name="learns" value="ko"/);
  assert.match(page, /name="engine" value="libre" x-model="engine" checked/);
  // 同意の文は、設定にだけある。
  assert.match(page, /DeepL を選ぶと/);

  const post = (b: URLSearchParams) =>
    go('/settings/translation', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: b });

  const noKey = new URLSearchParams([['engine', 'deepl']]);
  const refused = await post(noKey);
  assert.equal(refused.status, 422);
  assert.match(await refused.text(), /DeepL を使うには、キーが要ります/);

  const saved = await post(
    new URLSearchParams([
      ['reads', 'ja'],
      ['reads', 'en'],
      ['learns', 'ko'],
      ['engine', 'deepl'],
      ['translate_deepl_key', '123e4567-e89b-12d3-a456-426614174000:fx']
    ])
  );
  assert.equal(saved.status, 303);

  const after = await (await go('/settings/translation')).text();
  assert.match(after, /name="reads" value="en" checked/);
  assert.match(after, /name="learns" value="ko" checked/);
  assert.match(after, /name="engine" value="deepl" x-model="engine" checked/);
  assert.match(after, /…4000 で終わるキー/);
  assert.doesNotMatch(after, /123e4567/); // キーそのものは、二度と出ない
  // 消すボタンは、保存を待たない別の form(確認つき)。チェックボックスではない。
  assert.match(after, /<button type="submit" form="tr-key-clear" class="chip">キーを消す<\/button>/);
  assert.match(after, /<form id="tr-key-clear" method="post" action="\/settings\/translation\/key-clear" up-confirm="[^"]+"><\/form>/);
  assert.doesNotMatch(after, /translate_deepl_key_clear/);
});

test('設定のあと: 学んでいることばの投稿は「訳をひらく」、en を読めるので en の投稿は出ない', async () => {
  const page = await (await go('/')).text();
  const ko = page.slice(page.indexOf('id="st-1002"'), page.indexOf('id="st-1003"'));
  assert.match(ko, /tr-slot learn-on/);
  assert.match(ko, /訳をひらく/);
  assert.match(ko, /学んでいます/);
});

test('押す(DeepL を選んだあと): 訳の欄に DeepL と出る', async () => {
  const frag = await (
    await go('/statuses/1002/translate', {
      method: 'POST',
      headers: { ...up, 'content-type': 'application/x-www-form-urlencoded' },
      body: form({ dom: 'st-1002' })
    })
  ).text();
  assert.match(frag, /<span>DeepL<\/span>/);
});

test('キーを消す(ボタン → 確認 → この場所の訳し役に戻る)。読めることばは、そのまま', async () => {
  const res = await go('/settings/translation/key-clear', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: '' });
  assert.equal(res.status, 303);
  const page = await (await go('/settings/translation')).text();
  assert.match(page, /キーを消しました。訳し役は、この場所のものに戻っています/);
  assert.doesNotMatch(page, /で終わるキー/);
  assert.doesNotMatch(page, /tr-key-clear/); // 消したあとは、ボタンも出ない
  assert.match(page, /name="engine" value="libre" x-model="engine" checked/);
  assert.match(page, /name="reads" value="en" checked/);
  assert.match(page, /name="learns" value="ko" checked/);
});

test('JS なし(Unpoly なし)でも、押せば訳つきの頁が返る', async () => {
  const res = await go('/statuses/1002/translate', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: form({ dom: 'st-1002' })
  });
  assert.equal(res.status, 200);
  const page = await res.text();
  assert.match(page, /<html/);
  assert.match(page, /影島でコーヒー/);
});
