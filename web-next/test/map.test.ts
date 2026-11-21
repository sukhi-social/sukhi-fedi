// SPDX-License-Identifier: AGPL-3.0-or-later
// この星の路線図。数 → 列車の本数・星の置き場所(単体)と、頁・取りなおし(/map/live)・はかれないとき(偽の gateway を子プロセスで)。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawn, type ChildProcess } from 'node:child_process';
import { parseSample, placeStars, railRegion, starHash, starSize, trains, universeRegion } from '../server/views/map.ts';
import { makeT } from '../server/i18n.ts';
import { loggedOutServer } from './bell.ts';

const PORT = 5251;
const MOCK = 4251;
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

const get = (path: string) => fetch(`${BASE}${path}`, { redirect: 'manual' });
const mock = (query: string) => fetch(`${M}/map?${query}`, { method: 'POST' });
const log = async (): Promise<string[]> => (await fetch(`${M}/requests-log`)).json();

// 領域の印(data-v)と、中身。
const vOf = (page: string, name: string) => new RegExp(`data-map-region="${name}" data-v="([^"]+)"`).exec(page)?.[1];
function region(page: string, name: string): string {
  const i = page.indexOf(`data-map-region="${name}"`);
  assert.ok(i >= 0, `${name} がありません`);
  const end = { rail: '</svg>', board: '</section>', universe: 'それぞれの線のこと' }[name as 'rail']!;
  return page.slice(i, page.indexOf(end, i));
}
const moving = (s: string) => s.match(/repeatCount="indefinite"/g)?.length ?? 0;
const parked = (s: string) => s.match(/fill="freeze"/g)?.length ?? 0;

// ── 単体 ──────────────────────────────────────────────────────────

function assertNoOverlap(stars: { domain: string; x: number; y: number }[]) {
  for (const [i, p] of stars.entries()) {
    for (const q of stars.slice(i + 1)) {
      const w = (p.domain.length * 6.6 + 16 + q.domain.length * 6.6 + 16) / 2;
      assert.ok(Math.abs(p.x - q.x) >= w || Math.abs(p.y - q.y) >= 32, `${p.domain} と ${q.domain} が重なっています`);
    }
  }
}

test('列車の本数: 桁でゆっくり増える。0 以下は走らない。上限がある', () => {
  assert.deepEqual([0, -5, 1, 9, 10, 99, 100, 999, 1000, 99999].map((n) => trains(n)), [0, 0, 1, 1, 2, 2, 3, 3, 4, 4]);
  assert.equal(trains(1_000_000, 3), 3);
  assert.equal(trains(34, 3), 2);
});

test('はかった返事を読む: 読めなければ null、数は整数に、星は名前のあるものだけ', () => {
  for (const bad of [null, undefined, 'x', 3, {}, { at: 'いつか' }, { at: 5 }]) assert.equal(parseSample(bad), null);

  const s = parseSample({
    at: '2026-11-20T01:00:00Z',
    streams: { outbox: { seq: 1, held: 0 }, outbox_dlq: { seq: 1, held: 2.9 }, events: null },
    notes_24h: { local: 34.7, remote: -3 },
    deliveries_24h: '892',
    peers: [{ domain: 'a.example', notes_24h: 5 }, { domain: '' }, { notes_24h: 3 }, null, { domain: 7 }, { domain: 'b.example', notes_24h: 'many' }]
  });
  assert.deepEqual(s, {
    at: '2026-11-20T01:00:00Z',
    fedRunning: true,
    dlqHeld: 2,
    local: 34,
    remote: 0,
    deliveries: 0,
    peers: [{ domain: 'a.example', notes: 5 }, { domain: 'b.example', notes: 0 }]
  });

  // 連合線の数字が無い = 運転見合わせ。側線の数が無い = 取れない(null)。星の列が無くても、壊れない。
  const bare = parseSample({ at: '2026-11-20T01:00:00Z', streams: { outbox: null } });
  assert.equal(bare?.fedRunning, false);
  assert.equal(bare?.dlqHeld, null);
  assert.deepEqual(bare?.peers, []);

  // 星は、置く手間が増えすぎないよう、上限がある。
  const many = parseSample({ at: '2026-11-20T01:00:00Z', peers: Array.from({ length: 500 }, (_, i) => ({ domain: `p${i}.example`, notes_24h: 1 })) });
  assert.equal(many?.peers.length, 60);
});

test('星の置き場所: 同じ星ぞろえなら、いつも同じ空。枠の中に収まり、名前どうしが重ならない', () => {
  const peers = [
    { domain: 'natadeco.com', notes: 210 },
    { domain: 'hackers.pub', notes: 96 },
    { domain: 'mastodon.social', notes: 61 },
    { domain: 'misskey.io', notes: 24 }
  ];
  const a = placeStars(peers);
  assert.deepEqual(placeStars(peers), a);
  assert.deepEqual(a.map((s) => s.domain), peers.map((p) => p.domain));
  for (const s of a) {
    assert.ok(s.x >= 80 && s.x <= 880 && s.y >= 60 && s.y <= 370, `${s.domain} ${s.x},${s.y}`);
    assert.ok(!(Math.abs(480 - s.x) < (s.domain.length * 6.6 + 16) / 2 + 44 && Math.abs(215 - s.y) < 48), `${s.domain} が sukhi に重なっています`);
  }
  assertNoOverlap(a);
  // 混み合った空でも(ぶつかったら、外へ逃がす)。
  const crowd = placeStars(Array.from({ length: 20 }, (_, i) => ({ domain: `peer-${i}.example`, notes: i })));
  assertNoOverlap(crowd);
  // 上限の数でも、固まらない。
  const t0 = Date.now();
  assert.equal(placeStars(Array.from({ length: 60 }, (_, i) => ({ domain: `peer-${i}.example`, notes: i }))).length, 60);
  assert.ok(Date.now() - t0 < 500);

  assert.equal(starHash('a'), starHash('a'));
  assert.notEqual(starHash('a'), starHash('b'));
  assert.deepEqual([0, 1, 10, 100, 1e6].map(starSize), [3, 4.5, 6, 7.5, 9]);
});

test('乗り物: 走る組と停めた組が、同じ数だけ。数が変われば領域の印が変わり、同じなら同じ', () => {
  const base = { at: '2026-11-20T01:00:00Z', fedRunning: true, dlqHeld: 0, local: 34, remote: 1208, deliveries: 892, peers: [] };
  const a = railRegion(base).value;
  assert.equal(moving(a), 20); // 2 + 3 + (4+4) + (3+3) + 新幹線 1
  assert.equal(parked(a), 20);
  assert.equal(railRegion({ ...base }).value, a);
  assert.notEqual(railRegion({ ...base, local: 3000 }).value, a);

  // はかれなかったとき(null)は、新幹線(試運転中の一本)だけが走る。
  assert.equal(moving(railRegion(null).value), 1);
  // 側線に貨車が見えるのは、とまっている数(三両まで)。
  assert.equal(railRegion({ ...base, dlqHeld: 2 }).value.match(/class="held-car"/g)?.length, 2);
  assert.equal(railRegion({ ...base, dlqHeld: 9 }).value.match(/class="held-car"/g)?.length, 3);
  assert.equal(railRegion({ ...base, dlqHeld: null }).value.match(/held-car/g), null);
});

test('宇宙図: 星が一つも無ければ、章ごと出さない。領域は(差しかえの足場として)空のまま残る', () => {
  const tt = makeT('ja');
  const none = universeRegion(tt, null).value;
  assert.match(none, /^<div class="map-region" data-map-region="universe" data-v="[^"]+"><\/div>$/);
  const some = universeRegion(tt, {
    at: '2026-11-20T01:00:00Z', fedRunning: true, dlqHeld: 0, local: 0, remote: 0, deliveries: 0,
    peers: [{ domain: 'lit.example', notes: 5 }, { domain: 'quiet.example', notes: 0 }]
  }).value;
  assert.equal(some.match(/class="lane"/g)?.length, 2);
  assert.equal(some.match(/class="peer lit"/g)?.length, 1); // 便りのあった星だけ光る
  assert.equal(moving(some), 1); // ロケットも、便りのあった星からだけ
  assert.equal(parked(some), 1);
  assert.match(some, /href="#lane-0"/);
});

// ── 頁 ────────────────────────────────────────────────────────────

test('頁: 線路・乗り物・発車標・宇宙図・解説。数字は、はかった本物', async () => {
  await mock('reset=1');
  const res = await get('/map');
  assert.equal(res.status, 200);
  const page = await res.text();
  assert.match(page, /<h1>この星の、路線図<\/h1>/);
  assert.match(page, /<div class="map-page" data-map-live="\/map\/live">/);
  assert.match(page, /<header class="app-nav"/); // 入っている人には、いつもの屋根

  // 線路の id は、乗り物が mpath で指す先。
  for (const id of ['p-front', 'p-lightrail', 'p-fedout-rail', 'p-route-out', 'p-route-in', 'p-express', 'p-wt']) {
    assert.match(page, new RegExp(`id="${id}"`), id);
  }
  const rail = region(page, 'rail');
  assert.equal(moving(rail), 20);
  assert.equal(parked(rail), 20);
  assert.equal(rail.match(/class="held-car"/g)?.length, 2);

  const board = region(page, 'board');
  assert.match(board, /ことばの列車、この1日で 34 本/);
  assert.match(board, /連合ゆき、この1日で 892 便/);
  assert.match(board, /sukhi ゆき、この1日で 1208 本/);
  assert.match(board, /側線に 2 両/);
  assert.match(board, /新しい投稿のお知らせ、この1日で 1242 本/);
  assert.match(board, /class="map-asof"><time datetime="[^"]+">[^<]*現在<\/time>/);
  assert.equal(board.match(/運行中/g)?.length, 3); // おもて口線・連合線・場内放送(WT は試運転中)
  assert.match(board, /試運転中/);
  // はかれたので、「取れませんでした」は隠れている。
  assert.match(page, /<p class="map-error" data-map-error hidden>/);

  const universe = region(page, 'universe');
  for (const d of ['natadeco.com', 'hackers.pub', 'mastodon.social', 'misskey.io']) assert.match(universe, new RegExp(`>${d.replace('.', '\\.')}<`), d);
  assert.equal(universe.match(/class="lane"/g)?.length, 4);
  assert.equal(moving(universe), 4);

  assert.match(page, /それぞれの線のこと/);
});

test('頁は、入っていない人にも開いている。屋根のかわりに入口の帯・約束の足', async () => {
  const out = await loggedOutServer(5252, { ABOUT_URL: '' }); // トップの入口(about へ送らない設定)も見る
  try {
    const res = await fetch(`${out.base}/map`, { redirect: 'manual' });
    assert.equal(res.status, 200);
    const page = await res.text();
    assert.doesNotMatch(page, /<header class="app-nav"/);
    assert.match(page, /data-map-live/);
    assert.equal(moving(region(page, 'rail')), 20);

    // トップから、ここへ来られる。
    const top = await (await fetch(`${out.base}/`, { redirect: 'manual' })).text();
    assert.match(top, /<a href="\/map">この星の、路線図をみる<\/a>/);
    // 取りなおしも、入っていなくても開いている。
    assert.equal((await fetch(`${out.base}/map/live`)).status, 200);
  } finally {
    out.stop();
  }
});

// ── 取りなおし ────────────────────────────────────────────────────

test('取りなおし: 領域だけ(枠も屋根も無し)。印は頁と同じで、変わらないあいだは変わらない', async () => {
  await mock('reset=1');
  const page = await (await get('/map')).text();
  const res = await get('/map/live');
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type') ?? '', /^text\/html/);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  const live = await res.text();
  assert.doesNotMatch(live, /<!doctype|<html|<header|<h1/i);
  // rail は SVG の仲間なので、<svg> に包まれて届く(HTML の読みかたで外れないように)。
  assert.match(live, /^<svg><g data-map-region="rail"/);
  for (const name of ['rail', 'board', 'universe']) {
    assert.ok(vOf(live, name), name);
    assert.equal(vOf(live, name), vOf(page, name), `${name} の印が、頁とずれています`);
  }
  assert.equal(vOf(await (await get('/map/live')).text(), 'rail'), vOf(live, 'rail'));
});

test('取りなおしは、裏の問い合わせと名乗る(頁は、ふつうの問い合わせ)', async () => {
  await mock('reset=1');
  const before = (await log()).length;
  await get('/map');
  await get('/map/live');
  assert.deepEqual((await log()).slice(before), ['api/map', 'api/map bg']);
});

test('数が変われば、変わった領域の印だけが変わる', async () => {
  await mock('reset=1');
  const a = await (await get('/map/live')).text();
  try {
    await mock('local=3000'); // 34 → 3000: 列車の本数も、発車標の数字も変わる。星は変わらない
    const b = await (await get('/map/live')).text();
    assert.notEqual(vOf(b, 'rail'), vOf(a, 'rail'));
    assert.notEqual(vOf(b, 'board'), vOf(a, 'board'));
    assert.equal(vOf(b, 'universe'), vOf(a, 'universe'));
    assert.match(region(b, 'board'), /この1日で 3000 本/);

    await mock('reset=1');
    await mock('dlq=0'); // 側線が空になる: 貨車が消え、「からっぽです」
    const c = await (await get('/map/live')).text();
    assert.notEqual(vOf(c, 'rail'), vOf(a, 'rail'));
    assert.doesNotMatch(c, /held-car/);
    assert.match(c, /側線は、からっぽです/);
  } finally {
    await mock('reset=1');
  }
});

test('星が一つも選ばれていなければ、宇宙図の章は出ない', async () => {
  try {
    await mock('peers=none');
    const page = await (await get('/map')).text();
    assert.ok(vOf(page, 'universe'));
    assert.doesNotMatch(page, /連合の宇宙図/);
    assert.doesNotMatch(page, /class="lane"/);
    // 星があらわれたら、取りなおしで差せるように、領域は残っている。
    assert.match(page, /data-map-region="universe"/);
  } finally {
    await mock('reset=1');
  }
  assert.match(await (await get('/map')).text(), /連合の宇宙図/);
});

test('連合線の数字が取れないときは「運転見合わせ」(線路も、ほかの線の数字も、そのまま)', async () => {
  try {
    await mock('outbox=none');
    const page = await (await get('/map')).text();
    const board = region(page, 'board');
    assert.equal(board.match(/運転見合わせ/g)?.length, 2); // 連合線と、場内放送
    assert.equal(board.match(/運行中/g)?.length, 1); // おもて口線
    assert.match(board, /ことばの列車、この1日で 34 本/);
  } finally {
    await mock('reset=1');
  }
});

// ── はかれないとき ────────────────────────────────────────────────

test('gateway がはかれないとき: 頁は「はかっています…」と線路だけ。取りなおしは 502', async () => {
  try {
    await mock('down=1');
    const res = await get('/map');
    assert.equal(res.status, 200); // 線路の絵は、数字が無くても読める
    const page = await res.text();
    assert.match(page, /<p class="map-error" data-map-error>/); // 「取れませんでした」が見えている(hidden が付かない)
    assert.doesNotMatch(page, /data-map-error hidden/);
    assert.match(region(page, 'board'), /はかっています…/);
    assert.doesNotMatch(region(page, 'board'), /map-asof/); // はかれていないので、「現在」とは言わない
    assert.equal(moving(region(page, 'rail')), 1); // 試運転中の新幹線(状態を描く一本)だけ
    assert.doesNotMatch(page, /held-car/);
    assert.doesNotMatch(page, /連合の宇宙図/);

    assert.equal((await get('/map/live')).status, 502);
  } finally {
    await mock('reset=1');
  }
  assert.equal((await get('/map/live')).status, 200); // 戻れば、また取れる
});

// ── 動きを減らす設定 ──────────────────────────────────────────────

test('動きを減らす設定: 停めた組は、ふだんは隠れ、その設定のときだけ見える(CSS 一か所)', () => {
  const css = readFileSync(new URL('../public/css/extra.css', import.meta.url), 'utf8');
  assert.match(css, /\.map-parked\s*\{\s*display:\s*none;\s*\}/);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)\s*\{\s*\.map-moving\s*\{\s*display:\s*none;\s*\}\s*\.map-parked\s*\{\s*display:\s*inline;\s*\}\s*\}/);
});
