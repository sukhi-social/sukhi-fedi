// SPDX-License-Identifier: AGPL-3.0-or-later
// 通知のしるし(ベルの横の数・かたち)・「どこまで見たか」(gateway の印)・境い目の線・direct の呼び鈴(SSE)。
// 偽の gateway(印と、開いたままの流れを持つ)と郵便局を子プロセスで立てて、層ごとに歩く。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { dividerAfter, frames, newer } from '../server/notify.ts';
import { loggedOutServer, openBell as bellAt, streamsBecome as bellsBecome } from './bell.ts';

const PORT = 5245;
const MOCK = 4245;
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

const mockPost = (path: string) => fetch(`${M}/${path}`, { method: 'POST' });
// 新着を足して、その id を返す(流れが開いていれば、流れにも流れる)。
const add = async (type: string, stream = true): Promise<string> => ((await (await mockPost(`notify?type=${type}${stream ? '' : '&stream=0'}`)).json()) as { id: string }).id;
const setMarker = (to: string) => mockPost(`marker?to=${to}`);
const log = async (): Promise<string[]> => (await fetch(`${M}/requests-log`)).json();
// 通知をぜんぶ空にして、印を決める(none は「まだ置いていない」)。
const fresh = async (marker = 'none') => {
  await mockPost('notify?reset=empty');
  await setMarker(marker);
};
const text = async (path: string) => (await fetch(`${BASE}${path}`)).text();
const post = (path: string, headers: Record<string, string> = { origin: BASE }) => fetch(`${BASE}${path}`, { method: 'POST', headers, redirect: 'manual' });

// しるしの返事(四つの置き場)から、ひとつの置き場の中身を取り出す。
const slot = (html: string, id: string): string => new RegExp(`<span class="notif-slot" id="${id}">(.*?)</span></span>|<span class="notif-slot" id="${id}"></span>`).exec(html)?.[0] ?? '';
const directCount = (html: string): number => Number(/id="notif-direct-top"><span class="notif-count" aria-hidden="true">(\d+)</.exec(html)?.[1] ?? 0);
const hasGlyph = (html: string): boolean => /id="notif-ambient-top"><svg class="notif-glyph"/.test(html);

// ── 単体: 線を引く位置・新しさ・流れの読み ────────────────────────────

test('新しさ: 桁の長いほうが新しい。同じ桁なら辞書順', () => {
  assert.equal(newer('9010', '9005'), true);
  assert.equal(newer('10000', '9999'), true);
  assert.equal(newer('9005', '9005'), false);
  assert.equal(newer('9004', '9005'), false);
  assert.equal(newer('5', '0'), true);
  assert.equal(newer('0', '0'), false);
});

test('線の位置: 新着の最後と、最初の既読のあいだ', () => {
  const ids = (...xs: string[]) => xs.map((id) => ({ id }));
  // 新しい順。since=105 なら、107 と 106 が新着。
  assert.equal(dividerAfter(ids('107', '106', '105', '104'), '105', null, false), 1);
  assert.equal(dividerAfter(ids('105', '104'), '105', null, false), null); // 新着なし(最初の頁)
  assert.equal(dividerAfter([], '105', null, false), null);
  assert.equal(dividerAfter(ids('107', '106'), null, null, false), null); // 印が読めない
});

test('線の位置: 頁をまたぐ(ぜんぶ新着で次があれば、まだ引かない。前の頁が新着なら、頭に引く)', () => {
  const ids = (...xs: string[]) => xs.map((id) => ({ id }));
  assert.equal(dividerAfter(ids('109', '108', '107'), '105', null, true), null); // 境いは次の頁
  assert.equal(dividerAfter(ids('109', '108', '107'), '105', null, false), 2); // ここで終わるなら、最後の下
  assert.equal(dividerAfter(ids('105', '104'), '105', '106', true), -1); // 前の頁の最後(106)は新着、ここの最初は既読
  assert.equal(dividerAfter(ids('104', '103'), '105', '105', true), null); // 前の頁の最後がもう既読なら、すでに引いた
  assert.equal(dividerAfter(ids('107', '105', '104'), '105', '108', true), 0); // 頁の途中が境い
});

test('流れの読み: 空行で一フレーム。心拍(コメント)・\\r\\n・途中で切れた塊も読める', async () => {
  const enc = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    start(c) {
      c.enqueue(enc.encode(':thump\n\nevent: notif'));
      c.enqueue(enc.encode('ication\r\ndata: {"a":1}\r\n\r\nevent: x\ndata: 2\n\n'));
      c.enqueue(enc.encode('event: no-data\n\n')); // data が無ければ、フレームではない
      c.close();
    }
  });
  const got: { event: string; data: string }[] = [];
  for await (const f of frames(body)) got.push(f);
  assert.deepEqual(got, [
    { event: 'notification', data: '{"a":1}' },
    { event: 'x', data: '2' }
  ]);
});

// ── 数える ────────────────────────────────────────────────────────

test('ナビのしるしの置き場は、四つとも空で来る(頁を待たせない)。通知のリンクにだけ付く', async () => {
  const page = await text('/settings');
  assert.match(page, /<header class="app-nav" data-notif="\/notifications\/unseen" data-notif-stream="\/notifications\/stream">/);
  for (const id of ['notif-direct-top', 'notif-ambient-top', 'notif-direct-bottom', 'notif-ambient-bottom']) {
    assert.match(page, new RegExp(`<span class="notif-slot" id="${id}"></span>`));
  }
  assert.equal(page.match(/class="notif-slot"/g)?.length, 4);
});

test('はじめて(印が無い)は「いま」を起点に: 数は立たず、印を置く。そのあと来たものから数える', async () => {
  await fresh();
  await add('mention');
  const newest = await add('favourite');
  const first = await text('/notifications/unseen');
  assert.equal(directCount(first), 0);
  assert.equal(hasGlyph(first), false);
  assert.equal((await log()).at(-1), `marker ${newest}`);

  await add('mention');
  assert.equal(directCount(await text('/notifications/unseen')), 1);
});

test('一件も無い人は、印に「0」を置く ── 最初の一件を、見たことにしてしまわない', async () => {
  await fresh();
  const empty = await text('/notifications/unseen');
  assert.equal(directCount(empty), 0);
  assert.equal((await log()).at(-1), 'marker 0');
  await add('mention');
  assert.equal(directCount(await text('/notifications/unseen')), 1);
});

test('direct は数字、ambient は数字ではなく、数で育つかたち(、。w Λ A 木)', async () => {
  await fresh('0');
  await add('mention');
  await add('mention');
  const html = await text('/notifications/unseen');
  assert.equal(directCount(html), 2);
  assert.match(html, /あなたへの新しい通知が 2 件/);
  assert.equal(hasGlyph(html), false); // ambient が無ければ、かたちは出ない

  await fresh('0');
  // 反応の数 → かたち。境い目は 1 / 2〜3 / 4〜6 / 7〜11 / 12〜19 / 20〜。
  const stages: [number, RegExp][] = [
    [1, /<circle cx="6" cy="7\.5" r="1\.7"/],
    [3, /<circle cx="6" cy="6\.5" r="3" fill="none"/],
    [4, /<path d="M1\.5 8\.5 Q/],
    [7, /<path d="M2\.5 9\.5 L6 2\.8 L9\.5 9\.5" fill/],
    [12, /M4\.2 6\.9 L7\.8 6\.9/],
    [20, /<line x1="6" y1="10\.5"/]
  ];
  let have = 0;
  for (const [n, shape] of stages) {
    while (have < n) {
      await add('favourite');
      have++;
    }
    const got = await text('/notifications/unseen');
    assert.match(got, shape, `${n} 件のかたち`);
    assert.equal(directCount(got), 0);
    // 数字は、どこにも出ない(かたちは読み上げから隠れ、言葉だけが残る)。
    assert.doesNotMatch(slot(got, 'notif-ambient-top'), />\d+</);
    assert.match(got, /新しい反応があります/);
  }
});

// ── 見たことにする ────────────────────────────────────────────────

test('通知の頁を描くだけでは、印は動かない。POST /seen で、層をまたいで最新まで進む', async () => {
  await fresh('0');
  await add('mention');
  const newest = await add('favourite'); // いちばん新しいのは ambient
  const before = (await log()).length;

  const page = await text('/notifications');
  assert.match(page, /<div hidden data-mark-seen="\/notifications\/seen"><\/div>/);
  assert.equal((await log()).length, before, '頁を描いただけでは、印は書き換わらない');
  assert.equal(directCount(await text('/notifications/unseen')), 1);

  const res = await post('/notifications/seen');
  assert.equal(res.status, 204);
  assert.equal((await log()).at(-1), `marker ${newest}`);
  const after = await text('/notifications/unseen');
  assert.equal(directCount(after), 0);
  assert.equal(hasGlyph(after), false);
});

test('同じ origin でない POST は、断る(印は動かない)', async () => {
  await fresh('0');
  await add('mention');
  const before = (await log()).length;
  const res = await post('/notifications/seen', { origin: 'https://evil.example' });
  assert.equal(res.status, 403);
  assert.equal((await log()).length, before);
});

// ── 境い目の線 ────────────────────────────────────────────────────

const order = (page: string): string[] => [...page.matchAll(/id="nf-(\d+)"|class="notif-divider"/g)].map((m) => m[1] ?? 'LINE');

test('新しい通知は、ここまで: 新着と既読のあいだ。タブにも「もっと読む」にも、来たときの印を引き継ぐ', async () => {
  await fresh();
  const old = await add('mention');
  await setMarker(old);
  const a = await add('mention');
  const b = await add('mention');

  const page = await text('/notifications');
  assert.deepEqual(order(page), [b, a, 'LINE', old]);
  assert.match(page, new RegExp(`href="/notifications\\?tier=direct&amp;since=${old}"`));
  assert.match(page, new RegExp(`href="/notifications\\?tier=ambient&amp;since=${old}"`));

  // 印がその後に進んでも、引き継いだ印のほうが使われる(線が、動かない)。
  await setMarker(b);
  assert.deepEqual(order(await text(`/notifications?since=${old}`)), [b, a, 'LINE', old]);
  assert.deepEqual(order(await text(`/notifications?since=${a}`)), [b, 'LINE', a, old]);
  // 読めない印は、ないものとして、いまの印を使う(落ちない)。
  assert.deepEqual(order(await text('/notifications?since=abc')), [b, a, old]);
});

test('反応のタブにも線が引かれる。印が無ければ、線も引き継ぎも出ない', async () => {
  await fresh();
  const old = await add('favourite');
  await setMarker(old);
  const f1 = await add('reblog');
  const f2 = await add('follow');
  assert.deepEqual(order(await text('/notifications?tier=ambient')), [f2, f1, 'LINE', old]);

  await setMarker('none');
  const noMark = await text('/notifications?tier=ambient');
  assert.deepEqual(order(noMark), [f2, f1, old]);
  assert.doesNotMatch(noMark, /since=/);
});

// ── direct の呼び鈴(SSE) ─────────────────────────────────────────

const openBell = (method = 'GET') => bellAt(`${BASE}/notifications/stream`, { method });
const streamsBecome = (n: number) => bellsBecome(M, 'open', n);

test('呼び鈴: direct のぶんだけ、中身なしで鳴る。ambient と形のちがうフレームは、渡さない。去れば gateway の流れも閉じる', async () => {
  await fresh('0');
  await streamsBecome(0);
  const bell = await openBell();
  try {
    assert.equal(bell.res.status, 200);
    assert.match(bell.res.headers.get('content-type') ?? '', /^text\/event-stream/);
    assert.equal(bell.res.headers.get('x-accel-buffering'), 'no');
    assert.equal(bell.res.headers.get('cache-control'), 'no-store');
    assert.ok(await bell.until(/retry: 5000\n\n/));
    await streamsBecome(1);

    await add('favourite'); // ambient: 渡さない
    await mockPost('notify?raw=event:%20notification%0Adata:%20not-json'); // 形がちがう: 渡さない
    await mockPost('notify?raw=event:%20update%0Adata:%20%7B%7D'); // 通知ではない: 渡さない
    await add('mention'); // direct: 鳴る
    assert.ok(await bell.until(/event: direct\ndata: 1\n\n/));
    assert.equal(bell.text().match(/event: direct/g)?.length, 1);
    assert.doesNotMatch(bell.text(), /favourite|not-json|update/); // 中身は、一つも流れない

    await add('follow_request'); // これも direct
    await bell.until(/(event: direct[\s\S]*){2}/);
  } finally {
    bell.close();
  }
  await streamsBecome(0);
});

test('呼び鈴: gateway が流れを閉じたら、こちらも閉じる(ブラウザが繋ぎ直す)', async () => {
  await streamsBecome(0);
  const bell = await openBell();
  assert.ok(await bell.until(/retry: 5000/));
  await streamsBecome(1);
  await mockPost('stream-end');
  assert.equal(await bell.until(/never-appears/, 3000), false); // 閉じて、読み終わる
  await streamsBecome(0);
});

test('呼び鈴: gateway の流れの口が閉じているときは、200 で「あとでまた」と言って閉じる(EventSource は 200 でないと繋ぎ直さない)', async () => {
  await mockPost('stream-end?down=1');
  try {
    const res = await fetch(`${BASE}/notifications/stream`);
    assert.equal(res.status, 200);
    assert.equal(await res.text(), 'retry: 60000\n\n');
  } finally {
    await mockPost('stream-end?down=0');
  }
});

test('呼び鈴: HEAD では gateway の流れを残さない', async () => {
  await streamsBecome(0);
  const res = await fetch(`${BASE}/notifications/stream`, { method: 'HEAD' });
  assert.equal(res.status, 200);
  await streamsBecome(0);
});

test('入っていない人には、ログインの頁へ追わせず、401(数も、印も、流れも)', async () => {
  const out = await loggedOutServer(5249);
  try {
    assert.equal((await fetch(`${out.base}/notifications/unseen`, { redirect: 'manual' })).status, 401);
    assert.equal((await fetch(`${out.base}/notifications/seen`, { method: 'POST', redirect: 'manual', headers: { origin: out.base } })).status, 401);
    assert.equal((await fetch(`${out.base}/notifications/stream`, { redirect: 'manual' })).status, 401);
  } finally {
    out.stop();
  }
});
