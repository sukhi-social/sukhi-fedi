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

test('offerFor(自動): オンの人の、ことばが決まっていて、たたまれていない投稿だけ。学ぶことば・漢字だけ・内容警告は、ボタンのまま', () => {
  const on = prefsOf({ ...me, source: { translate_auto: true } } as Account, 'ja');
  const ko = '<p>오늘은 비가 와서 집에 있었어요.</p>';
  assert.equal(on.auto, true);
  assert.equal(offerFor(post(ko), me, on, true), 'auto');
  assert.equal(offerFor(post('<p>Finally finished the scarf.</p>'), me, on, true), 'auto');
  assert.equal(offerFor(post('<p>今日天気很好</p>'), me, on, true), 'ask'); // ことばが決まらない
  assert.equal(offerFor(post(ko, { spoiler_text: '愚痴' }), me, on, true), 'ask'); // たたまれている
  assert.equal(offerFor(post(ko), me, { ...on, learns: ['ko'] }, true), 'learn'); // 学んでいる: まず自分で読む
  assert.equal(offerFor(post(ko, { visibility: 'direct' }), me, on, true), 'none');
  // 既定はオフ。
  assert.equal(prefsOf(me, 'ja').auto, false);
  assert.equal(offerFor(post(ko), me, prefsOf(me, 'ja'), true), 'ask');
});

// ── 端から端まで ───────────────────────────────────────────────
const PORT = 5194;
const BASE = `http://localhost:${PORT}`;
const MOCK = `http://localhost:4194`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4194', PUBLIC_ORIGIN: BASE, ME_TTL_MS: '300' },
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

// ── 静かな自動翻訳(docs/TRANSLATION_AUTO.md)──────────────────────
const formHeaders = { 'content-type': 'application/x-www-form-urlencoded' };
const saveSettings = (pairs: [string, string][]) =>
  go('/settings/translation', { method: 'POST', headers: formHeaders, body: new URLSearchParams(pairs) });
const press = (o: Record<string, string>) =>
  go('/statuses/1002/translate', { method: 'POST', headers: { ...up, ...formHeaders }, body: form({ dom: 'st-1002', ...o }) });
const resetMock = () => fetch(`${MOCK}/__mock/translate`, { method: 'POST' });

test('自動(設定): 既定はオフ。オンにすると、二行の注意書きと「くわしく」。保存して、戻ってもオン', async () => {
  const before = await (await go('/settings/translation')).text();
  assert.match(before, /name="auto" value="1" x-model="auto"\s*\/>/); // 既定は、チェックなし
  assert.match(before, /画面に入った投稿を、自動で訳す/);
  assert.match(before, /画面に少し留まった投稿の本文が、訳し役に渡されます/);
  assert.match(before, /<summary>くわしく<\/summary>/);

  const saved = await saveSettings([['reads', 'ja'], ['reads', 'en'], ['engine', 'libre'], ['auto', '1']]);
  assert.equal(saved.status, 303);
  const after = await (await go('/settings/translation')).text();
  assert.match(after, /name="auto" value="1" x-model="auto" checked/);
});

test('自動(ホーム): 読めないことば(ko)の投稿の「訳を見る」に、自動の印がつく。日本語の投稿には何も出ない', async () => {
  const page = await (await go('/')).text();
  const ko = page.slice(page.indexOf('id="st-1002"'), page.indexOf('id="st-1003"'));
  assert.match(ko, /<form[^>]*data-tr-auto/);
  assert.match(ko, /name="auto" value=""/); // 手で押したときは、空のまま
  assert.match(ko, /訳を見る/); // ボタンは、いつもそこにある
  const ja = page.slice(page.indexOf('id="st-1003"'), page.indexOf('id="st-1004"'));
  assert.doesNotMatch(ja, /tr-slot/);
});

test('自動(押される): 淡い訳が足され、ラベルに「自動」とエンジン名。gateway には auto として伝わる', async () => {
  await fetch(`${MOCK}/__mock/translate-log`); // 記録は、ここから先を見る
  const before = ((await (await fetch(`${MOCK}/__mock/translate-log`)).json()) as boolean[]).length;
  const frag = await (await press({ auto: '1' })).text();
  assert.match(frag, /class="tr-box auto"/);
  assert.match(frag, /訳\(機械翻訳・自動\)/);
  assert.match(frag, /LibreTranslate/);
  assert.match(frag, /影島でコーヒー/);
  assert.match(frag, /とじる/);
  assert.doesNotMatch(frag, /data-tr-auto/); // 訳した slot は、もう一度は試さない
  const log = (await (await fetch(`${MOCK}/__mock/translate-log`)).json()) as boolean[];
  assert.deepEqual(log.slice(before), [true]);
});

test('手で押したときは、自動と名乗らない(ラベルも、gateway への言い分も)', async () => {
  const log0 = ((await (await fetch(`${MOCK}/__mock/translate-log`)).json()) as boolean[]).length;
  const frag = await (await press({})).text();
  assert.match(frag, /<span>訳\(機械翻訳\)<\/span>/);
  assert.doesNotMatch(frag, /自動/);
  assert.doesNotMatch(frag, /tr-box auto/);
  const log = (await (await fetch(`${MOCK}/__mock/translate-log`)).json()) as boolean[];
  assert.deepEqual(log.slice(log0), [false]);
});

test('自動(混んでいる): 何も言わず、押せるボタンに戻る。自動の印は外れる(試し続けない)', async () => {
  await fetch(`${MOCK}/__mock/translate?fail=busy`, { method: 'POST' });
  const frag = await (await press({ auto: '1' })).text();
  assert.match(frag, /data-tr-quiet="busy"/);
  assert.doesNotMatch(frag, /tr-note/);
  assert.doesNotMatch(frag, /混んでいます/);
  assert.match(frag, /action="\/statuses\/1002\/translate"/);
  assert.match(frag, /訳を見る/);
  assert.doesNotMatch(frag, /data-tr-auto/);
  await resetMock();
});

test('自動(月の分を使いきった): これは言う ── 一度、設定への道つきで。自動はお休み(data-tr-rest)', async () => {
  await fetch(`${MOCK}/__mock/translate?fail=quota`, { method: 'POST' });
  const frag = await (await press({ auto: '1' })).text();
  assert.match(frag, /data-tr-rest/);
  assert.match(frag, /今月の分を使いきりました/);
  assert.match(frag, /自動の翻訳は、このページではお休みします/);
  assert.match(frag, /href="\/settings\/translation"/);
  await resetMock();
});

test('自動(読めることばだった): 何も出さず、ボタンも消える', async () => {
  // モックの訳し役は、いつも ko と見分ける。ko を読めることばにして試す。
  await saveSettings([['reads', 'ja'], ['reads', 'ko'], ['engine', 'libre'], ['auto', '1']]);
  const frag = await (await press({ auto: '1' })).text();
  const i = frag.indexOf('id="tr-st-1002"');
  assert.ok(i >= 0);
  const slot = frag.slice(i, frag.indexOf('</div>', frag.indexOf('id="tr-st-1002-body"')) + 6); // 訳の場所だけ(カードのほかの form は含めない)
  assert.match(slot, /id="tr-st-1002-body"/);
  assert.doesNotMatch(slot, /tr-box|<form|訳を見る/);
  // 手で押した訳は、読めることばでも、そのまま見せる(押したのだから)。
  const manual = await (await press({})).text();
  assert.match(manual, /class="tr-box"/);
});

test('自動(オフにしたあと): gateway が auto_off と断る。黙って、ボタンのまま(お休みの印)', async () => {
  await saveSettings([['reads', 'ja'], ['engine', 'libre']]); // auto を送らない = オフ
  const page = await (await go('/settings/translation')).text();
  assert.doesNotMatch(page, /name="auto" value="1" x-model="auto" checked/);
  const frag = await (await press({ auto: '1' })).text();
  assert.match(frag, /data-tr-quiet="auto_off"/);
  assert.doesNotMatch(frag, /tr-note/);
  assert.match(frag, /訳を見る/);
  const home = await (await go('/')).text();
  assert.doesNotMatch(home, /data-tr-auto/); // オフなら、印は付かない
});

// ── 別の端末・別のタブ(= 別の session)でも、設定は同じ ─────────────
// session の「自分」のひかえは、その session の中だけで更新されていた ── 別の端末で変えた設定が届かず、
// 設定の頁も、ホームの「訳を見る」も、古いまま。一定の間(ME_TTL_MS)を過ぎたら引きなおし、設定の頁は毎回引く。
const otherDevice = async () => {
  const first = await fetch(`${BASE}/settings/translation`, { redirect: 'manual', headers: { origin: BASE } });
  const cookie = first.headers.get('set-cookie')?.split(';')[0] ?? '';
  assert.ok(cookie, '別の session が始まる');
  const get = (path: string) => fetch(`${BASE}${path}`, { redirect: 'manual', headers: { cookie, origin: BASE } }).then((r) => r.text());
  return { get };
};

test('別の端末: 設定の頁は、いつも gateway の今を見せる(待たずに届く)', async () => {
  const b = await otherDevice();
  const before = await b.get('/settings/translation');
  assert.doesNotMatch(before, /name="auto" value="1" x-model="auto" checked/);

  await saveSettings([['reads', 'ja'], ['reads', 'fr'], ['learns', 'ko'], ['engine', 'libre'], ['auto', '1']]); // こちらで変える

  const after = await b.get('/settings/translation');
  assert.match(after, /name="auto" value="1" x-model="auto" checked/);
  assert.match(after, /name="reads" value="fr" checked/);
  assert.match(after, /name="learns" value="ko" checked/);
});

test('別の端末: ホームの「訳を見る」も、しばらくすると今の設定に揃う', async () => {
  await saveSettings([['reads', 'ja'], ['reads', 'ko'], ['engine', 'libre']]); // ko は読める
  const b = await otherDevice();
  const koCard = (page: string) => page.slice(page.indexOf('id="st-1002"'), page.indexOf('id="st-1003"'));
  assert.doesNotMatch(koCard(await b.get('/')), /action="\/statuses\/1002\/translate"/); // 読めるので、出ない

  await saveSettings([['reads', 'ja'], ['engine', 'libre']]); // こちらで、ko を読めないことにする
  await new Promise((r) => setTimeout(r, 400)); // ひかえが古くなるまで

  const later = koCard(await b.get('/'));
  assert.match(later, /action="\/statuses\/1002\/translate"/);
  assert.match(later, /訳を見る/);
});
