// SPDX-License-Identifier: AGPL-3.0-or-later
// Clips(自分あての会話を、メモ置き場に): 頁の形・置く・探す・ピン・もっと古いほう・呼び鈴のあとの取りなおし・呼び鈴。
// 偽の gateway(自分あての会話 c0 を、状態つきで持つ)と郵便局を子プロセスで立てて、歩く。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { copyText, isPinned, withoutAddress } from '../server/views/clips.ts';
import { loggedOutServer, openBell, streamsBecome } from './bell.ts';

const PORT = 5253;
const MOCK = 4253;
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
const post = (path: string, fields: [string, string | File][] = [], headers: Record<string, string> = {}) => {
  const fd = new FormData();
  for (const [k, v] of fields) fd.append(k, v);
  return go(path, { method: 'POST', body: fd, headers });
};
const mockPost = (path: string) => fetch(`${M}/${path}`, { method: 'POST' });
const log = async (): Promise<string[]> => (await fetch(`${M}/requests-log`)).json();
const reset = (q = 'reset=1') => mockPost(`clips?${q}`);
const talks = (n: number) => streamsBecome(M, 'talks', n);
const UP = { 'x-up-version': '3.15.0' };

// 頁の中のクリップの id を、並んだ順に。
const ids = (html: string) => [...html.matchAll(/<article class="clip" id="clip-(\d+)"/g)].map((m) => m[1]);
// 一枚ぶん(次のクリップの頭、または、その外の枠の頭まで)。
const one = (html: string, id: string) => new RegExp(`<article class="clip" id="clip-${id}"[\\s\\S]*?</article>`).exec(html)?.[0] ?? '';
const png = (name: string, bytes = 8) => new File([new Uint8Array(bytes).fill(1)], name, { type: 'image/png' });

// ── 単体 ──────────────────────────────────────────────────────────

const HCARD = '<span class="h-card"><a href="https://x.example/@kuro" class="u-url mention">@<span>kuro</span></a></span>';

test('宛名を外す: 頭の言及(h-card も、むき出しも)と、言及だけの末尾の段落。文中の言及は、そのまま', () => {
  assert.equal(withoutAddress(`<p>${HCARD} メモ</p>`), '<p>メモ</p>'); // 宛名のあとの空白も、いっしょに(web の splitLeadingMentions と同じ)
  assert.equal(withoutAddress('<p>@kuro メモ</p>'), '<p>メモ</p>');
  assert.equal(withoutAddress(`<p>${HCARD} ${HCARD} ふたり宛て</p>`), '<p>ふたり宛て</p>');
  assert.equal(withoutAddress(`<p>${HCARD}</p>`), '<p></p>'); // ファイルだけのとき: 本文は空
  assert.equal(withoutAddress(`<p>メモ ${HCARD} 文中</p>`), `<p>メモ ${HCARD} 文中</p>`); // 文中は触らない
  assert.equal(withoutAddress('<p>メモ</p>'), '<p>メモ</p>');
  assert.equal(withoutAddress(`<p>一つめ</p><p>${HCARD}</p>`), '<p>一つめ</p>'); // web の書きかた: 宛名は末尾の段落
  assert.equal(withoutAddress(`<p>一つめ</p><p>${HCARD} 文が混じる</p>`), `<p>一つめ</p><p>${HCARD} 文が混じる</p>`); // 文が混じれば、書き手のもの
  assert.equal(withoutAddress('宛名のない 文字だけ'), '宛名のない 文字だけ');
  assert.equal(withoutAddress(null), '');
  assert.equal(withoutAddress(undefined), '');
});

test('コピーする字: 段落・改行は改行に、タグは外し、リンクは省略されない全文で', () => {
  assert.equal(copyText('<p>一</p><p>二</p>'), '一\n\n二');
  assert.equal(copyText('<p>一<br>二</p>'), '一\n二');
  assert.equal(copyText('<p>a &amp; b &lt;c&gt; &quot;d&quot; e&nbsp;f</p>'), 'a & b <c> "d" e f');
  assert.equal(
    copyText('<p><a href="https://ex.com/a"><span class="invisible">https://</span><span class="ellipsis">ex.com/a</span><span class="invisible">bc</span></a></p>'),
    'https://ex.com/abc'
  );
  assert.equal(copyText('<p></p>'), '');
});

test('ピン済みか: 📌 を、自分が押しているときだけ', () => {
  const s = (reactions: { name: string; count: number; me: boolean }[]) => ({ reactions }) as never;
  assert.equal(isPinned(s([{ name: '📌', count: 1, me: true }])), true);
  assert.equal(isPinned(s([{ name: '📌', count: 1, me: false }])), false);
  assert.equal(isPinned(s([{ name: '☺️', count: 1, me: true }])), false);
  assert.equal(isPinned({} as never), false);
});

// ── 頁 ────────────────────────────────────────────────────────────

test('頁: 古い順に並び、宛名は外れ、画像とファイルと、ピンと、コピーがある', async () => {
  await reset();
  const page = await (await go('/clips')).text();
  assert.deepEqual(ids(page), ['4001', '4002', '4003', '4004']);
  assert.doesNotMatch(page, /class="h-card"/); // 宛名は、どの一枚にも出ない
  assert.match(one(page, '4001'), /https:\/\/example\.com\/tea-roasting あとで読む/);

  // ピン: 押しているものだけ aria-pressed、押すと外す(on=0)、押していなければ付ける(on=1)
  assert.match(one(page, '4002'), /<input type="hidden" name="emoji" value="📌" \/>\s*<input type="hidden" name="on" value="0" \/>\s*<button type="submit" class="reaction-chip pin-toggle me" aria-pressed="true"/);
  assert.match(one(page, '4001'), /name="on" value="1" \/>\s*<button type="submit" class="reaction-chip pin-toggle " aria-pressed="false"/);

  // コピー: 文字のあるクリップにだけ。字は data-copy に、組んだまま
  assert.match(one(page, '4001'), /data-copy="https:\/\/example\.com\/tea-roasting あとで読む"/);
  assert.doesNotMatch(one(page, '4004'), /copy-toggle/); // ファイルだけ

  // 画像: 本物の画像として(押すと元の大きさを別窓で)。altは持ち主が付けたまま
  assert.match(one(page, '4003'), /<a class="clip-image" href="data:image\/svg\+xml[^"]*" target="_blank" rel="noopener noreferrer"><img src="data:image\/svg\+xml[^"]*" alt="湯気の立つ急須" loading="lazy" \/><\/a>/);

  // ファイル: 中身は見せず、拡張子と名前だけ。download と、別窓
  assert.match(one(page, '4004'), /<a class="clip-file" href="http:\/\/localhost\/uploads\/a2" target="_blank" rel="noopener noreferrer" download="recipe\.pdf">\s*<span class="clip-ext" aria-hidden="true">PDF<\/span><span class="clip-fname">recipe\.pdf<\/span>/);

  // ほかのリアクションは、ピンとは別に並ぶ。📌 は、その他の方には二度出ない
  assert.match(one(page, '4003'), /name="emoji" value="☺️"[\s\S]*?name="on" value="0"/);
  assert.equal(one(page, '4002').match(/name="emoji" value="📌"/g)?.length, 1);

  // 時刻だけ(名前もアバターも出さない)と、足す口
  assert.match(one(page, '4001'), /<a class="clip-when" href="\/@kuro\/4001"><time datetime="[^"]+">[^<]+<\/time><\/a>/);
  assert.match(one(page, '4001'), /href="\/statuses\/4001\/react\?d=clip-4001" up-target="#rp-clip-4001"/);
  assert.doesNotMatch(one(page, '4001'), /<img class="avatar|display-name/);

  // 書く欄: どんなファイルでも(accept は */*)、複数。箱の外
  assert.match(page, /<form class="room-write clips-write" method="post" action="\/clips" enctype="multipart\/form-data"/);
  assert.match(page, /<input type="file" name="files" accept="\*\/\*" multiple/);
  assert.ok(page.indexOf('id="clips-old"') < page.indexOf('class="room-write clips-write"'));

  // 開いたら下へ(古い順の、いちばん新しいところ)。呼び鈴の箱は、頁を開いたあとに届くぶんだけを訊く
  assert.match(page, /class="timeline stack clips-page" data-clips data-clips-bottom>/);
  assert.match(page, /<div id="clips-new" class="clips-list" data-room-live="\/clips" data-room-query="\?since=4004"><\/div>/);
});

test('Clips は、どこからもリンクしない(web も、直 URL だけ)', async () => {
  const home = await (await go('/')).text();
  assert.doesNotMatch(home, /href="\/clips/);
});

test('ピンだけ: ?pinned=1 は、ピンのものだけ。呼び鈴の箱にも引き継ぐ', async () => {
  await reset();
  const page = await (await go('/clips?pinned=1')).text();
  assert.deepEqual(ids(page), ['4002']);
  assert.match(page, /data-room-query="\?since=4004&amp;pinned=1"/);
  assert.match(page, /<a class="chip" href="\/clips" aria-pressed="true">すべて表示<\/a>/);
  assert.match(await (await go('/clips')).text(), /<a class="chip" href="\/clips\?pinned=1" aria-pressed="false">ピン留めのみ<\/a>/);
});

test('ピンだけで、ピンが一つも無いとき: ことばを出す(頁は空にしない)', async () => {
  await reset();
  await post('/statuses/4002/react', [['emoji', '📌'], ['on', '0']], { 'x-up-target': '#clip-4002', ...UP });
  const page = await (await go('/clips?pinned=1')).text();
  assert.deepEqual(ids(page), []);
  assert.match(page, /<p class="prose-small clips-empty">ピン留めされた Clip は、まだありません。<\/p>/);
  await reset();
});

test('探す: ?q= は、gateway の検索に渡す。呼び鈴の箱は無く、下へも送らない。探しているあいだはピンの絞りこみは効かない', async () => {
  await reset();
  const before = (await log()).length;
  const page = await (await go('/clips?q=ほうじ')).text();
  assert.deepEqual(ids(page), ['4002']);
  assert.ok((await log()).slice(before).some((l) => l.startsWith('clips list q=ほうじ ')));
  assert.doesNotMatch(page, /data-room-live/);
  assert.doesNotMatch(page, /data-clips-bottom/);
  assert.match(page, /<input class="fill" type="search" name="q" value="ほうじ"/);

  const none = await (await go('/clips?q=zzzz')).text();
  assert.deepEqual(ids(none), []);
  assert.match(none, /<p class="prose-small clips-empty">見つからなかった。<\/p>/);

  // ピンの絞りこみ(pinned=1)があっても、探しているあいだは、探した結果が出る(4001 はピンでないが、出る)
  assert.deepEqual(ids(await (await go('/clips?q=example&pinned=1')).text()), ['4001']);

  // 名前を持つ書き手の検索語は、属性のなかでも、ほどけない
  const evil = await (await go(`/clips?q=${encodeURIComponent('"><script>x</script>')}`)).text();
  assert.doesNotMatch(evil, /<script>x<\/script>/);
});

test('もっと古いほうへ: 一頁 20 件。道は、探しかた・絞りかたを引き継ぐ。古いほうだけの頁は、下へ送らず、呼び鈴も付けない', async () => {
  await reset('reset=1&fill=30'); // 4 + 30 = 34 件
  const page = await (await go('/clips')).text();
  assert.equal(ids(page).length, 20);
  assert.equal(ids(page).at(-1), '4004'); // いちばん新しいのが、下
  const more = /<a class="clips-older" href="([^"]+)" up-target="#clips-old:before, #clips-more" up-history="false" up-scroll="false" up-revalidate="false">もっと読む<\/a>/.exec(page);
  assert.ok(more, 'もっと読む');
  assert.match(more![1], /^\/clips\?max_id=\d+$/);

  const older = await (await go(more![1].replace(/&amp;/g, '&'))).text();
  assert.equal(ids(older).length, 14);
  assert.ok(Number(ids(older).at(-1)) < Number(ids(page)[0])); // 続き: 重ならない
  assert.doesNotMatch(older, /class="clips-older"/); // もう無い
  assert.doesNotMatch(older, /data-clips-bottom|data-room-live/);

  // 絞りこみを引き継ぐ
  assert.match(await (await go('/clips?q=むかし')).text(), /href="\/clips\?max_id=\d+&amp;q=%E3%82%80%E3%81%8B%E3%81%97"/);
  // ピンの絞りこみは、いま開いた一頁の中だけ(gateway は、ピンで絞れない)。もっと古いほうにも、ピンがあるかもしれないので、道は残り、絞りこみを引き継ぐ
  const pinnedPage = await (await go('/clips?pinned=1')).text();
  assert.deepEqual(ids(pinnedPage), ['4002']);
  assert.match(pinnedPage, /href="\/clips\?max_id=\d+&amp;pinned=1"/);

  // 読めない max_id は、ふつうの頁
  assert.equal(ids(await (await go('/clips?max_id=abc')).text()).length, 20);
  await reset();
});

test('まだ一通も無い人: ことばと書く欄だけ。呼び鈴の箱は無い。はじめの一通が、部屋を作る', async () => {
  await reset('reset=empty');
  const page = await (await go('/clips')).text();
  assert.deepEqual(ids(page), []);
  assert.match(page, /<p class="prose-small clips-empty">まだ、なにも置かれていません。/);
  assert.doesNotMatch(page, /data-room-live/);
  assert.match(page, /<textarea name="body"/);
  assert.equal((await go('/clips/stream')).status, 404); // 部屋が無い: EventSource は繋ぎ直さない

  const before = (await log()).length;
  const res = await post('/clips', [['body', 'はじめの一通']]);
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/clips');
  assert.deepEqual((await log()).slice(before).filter((l) => l.startsWith('clip ')), ['clip {"text":"@kuro はじめの一通","reply":null,"media":[]}']);
  const after = await (await go('/clips')).text();
  assert.equal(ids(after).length, 1);
  assert.match(after, /はじめの一通/);
  await reset();
});

// ── 置く ──────────────────────────────────────────────────────────

test('置く: 自分あての DM(頭に自分の @)・直前の一通への返信・お預かりなし(その場で上がる)', async () => {
  await reset();
  const before = (await log()).length;
  const res = await post('/clips', [['body', '  二行の\nメモ  ']]);
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/clips');
  // clip の記録は、お預かり(scheduled_at)でないときだけ残る。改行は、ブラウザの textarea と同じく CRLF で届く(rooms と同じ道。gateway が <br> にする)
  assert.deepEqual((await log()).slice(before).filter((l) => l.startsWith('clip ')), ['clip {"text":"@kuro 二行の\\r\\nメモ","reply":"4004","media":[]}']);
  const page = await (await go('/clips')).text();
  assert.equal(ids(page).length, 5);
  assert.match(one(page, ids(page).at(-1)!), /二行の<br>メモ/);
});

test('置く: 空は断る(書いたものは残す)。長すぎるのも', async () => {
  await reset();
  const before = (await log()).length;
  const empty = await post('/clips', [['body', '   ']]);
  assert.equal(empty.status, 422);
  assert.match(await empty.text(), /何か書いてから送ってくださいね。/);

  const long = await post('/clips', [['body', 'あ'.repeat(5001)]]);
  assert.equal(long.status, 422);
  const text = await long.text();
  assert.match(text, /長すぎます。/);
  assert.match(text, new RegExp(`あ{5001}</textarea>`)); // 書いたものは、残る
  assert.equal((await log()).slice(before).filter((l) => l.startsWith('clip ')).length, 0);
});

test('置く: ファイルだけでもいい。どんな種類でも。四つまで。大きさ・名前・alt の無いまま、gateway へ', async () => {
  await reset();
  const before = (await log()).length;
  const res = await post('/clips', [
    ['files', png('a.png', 5)],
    ['files', new File([new Uint8Array(3).fill(2)], 'memo.pdf', { type: 'application/pdf' })],
    ['files', new File([new Uint8Array(4).fill(3)], 'noext', { type: '' })],
    ['files', png('d.png', 6)],
    ['files', png('e.png', 7)], // 五つめ: 置かれない
    ['files', new File([], '')] // 選ばなかったときの、空のもの
  ]);
  assert.equal(res.status, 303);
  const fresh = (await log()).slice(before);
  assert.deepEqual(fresh.filter((l) => l.startsWith('media ')), ['media a.png 5 ', 'media memo.pdf 3 ', 'media noext 4 ', 'media d.png 6 ']);
  const made = fresh.find((l) => l.startsWith('clip '))!;
  assert.match(made, /^clip \{"text":"@kuro","reply":"4004","media":\["m\d+","m\d+","m\d+","m\d+"\]\}$/);

  // 画像でないものは、ファイルとして、名前つきで。名前の無いものは、拡張子が「?」
  const page = await (await go('/clips')).text();
  const card = one(page, ids(page).at(-1)!);
  assert.match(card, /<span class="clip-ext" aria-hidden="true">PDF<\/span><span class="clip-fname">memo\.pdf<\/span>/);
  assert.match(card, /<span class="clip-ext" aria-hidden="true">\?<\/span><span class="clip-fname">noext<\/span>/);
  assert.equal(card.match(/class="clip-image"/g)?.length, 2);
  assert.doesNotMatch(card, /clip-body/); // 本文は無い
  assert.doesNotMatch(card, /copy-toggle/);
});

test('置く: 点で始まる名前(.profile)は、名前の一部。拡張子は無いので「?」', async () => {
  await reset();
  await post('/clips', [['files', new File([new Uint8Array(2).fill(4)], '.profile', { type: '' })]]);
  const page = await (await go('/clips')).text();
  assert.match(one(page, ids(page).at(-1)!), /<span class="clip-ext" aria-hidden="true">\?<\/span><span class="clip-fname">\.profile<\/span>/);
  await reset();
});

test('置く: 大きすぎるファイルは、gateway が断る ── 書いたものは残し、頁にそのまま返す(置かれない)', async () => {
  await reset();
  const before = (await log()).length;
  const res = await post('/clips', [['body', '大きいのを添えます'], ['files', png('big.png', 9 * 1024 * 1024)]]);
  assert.equal(res.status, 422);
  const page = await res.text();
  assert.match(page, /role="alert"/);
  assert.match(page, /大きいのを添えます<\/textarea>/);
  assert.equal((await log()).slice(before).filter((l) => l.startsWith('clip ')).length, 0);
});

// ── ピンと、ほかのリアクション ───────────────────────────────────────

test('ピン: Unpoly の押しかたは、押した一枚(クリップの姿)だけを返す。投稿のカードではなく', async () => {
  await reset();
  const res = await post('/statuses/4001/react', [['emoji', '📌'], ['on', '1']], { 'x-up-target': '#clip-4001', ...UP });
  assert.equal(res.status, 200);
  const card = await res.text();
  assert.match(card, /^<article class="clip" id="clip-4001" data-in-place>/);
  assert.doesNotMatch(card, /class="status/);
  assert.match(card, /pin-toggle me" aria-pressed="true"/);
  assert.match(card, /name="on" value="0"/); // 次に押せば、外れる
  assert.ok((await log()).includes('react PUT 4001 📌'));

  // 外す
  const off = await (await post('/statuses/4001/react', [['emoji', '📌'], ['on', '0']], { 'x-up-target': '#clip-4001', ...UP })).text();
  assert.match(off, /pin-toggle " aria-pressed="false"/);
  assert.ok((await log()).includes('react DELETE 4001 📌'));

  // 頁にも、押したあとの姿で出る
  await post('/statuses/4001/react', [['emoji', '📌'], ['on', '1']], { 'x-up-target': '#clip-4001', ...UP });
  assert.deepEqual(ids(await (await go('/clips?pinned=1')).text()), ['4001', '4002']);
});

test('ピン: Unpoly でなければ、元の頁(referer)へ戻す。JavaScript が無くても押せる', async () => {
  await reset();
  const res = await post('/statuses/4001/react', [['emoji', '📌'], ['on', '1']], { referer: `${BASE}/clips?pinned=1` });
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/clips?pinned=1');
});

test('リアクションを足す: 選び口はクリップの箱に開き、選ぶと、クリップの姿で返る', async () => {
  await reset();
  const picker = await (await go('/statuses/4001/react?d=clip-4001')).text();
  assert.match(picker, /^<div id="rp-clip-4001" class="emoji-picker"/);
  assert.match(picker, /<form method="post" action="\/statuses\/4001\/react" in-place>/);

  const card = await (await post('/statuses/4001/react', [['emoji', ':tea:'], ['on', '1']], { 'x-up-target': '#clip-4001', ...UP })).text();
  assert.match(card, /^<article class="clip" id="clip-4001"/);
  assert.match(card, /name="emoji" value=":tea:"[\s\S]*?name="on" value="0"/); // 自分が押した
  assert.match(card, /<div id="rp-clip-4001"><\/div>/); // 選び口は、たたまれる
  assert.doesNotMatch(card, /pin-toggle me/); // ピンは、別
});

// ── 呼び鈴のあとの取りなおし ───────────────────────────────────────────

test('取りなおし: 頁を開いてから届いたぶんだけ、古い順に。クリップの姿で、枠も書く欄も付かない', async () => {
  await reset();
  const none = await go('/clips/talk?since=4004');
  assert.equal(none.status, 200);
  assert.match(none.headers.get('content-type') ?? '', /^text\/html/);
  assert.equal((await none.text()).trim(), ''); // まだ、何も届いていない

  await post('/clips', [['body', 'ひとつめ']]);
  await post('/clips', [['body', 'ふたつめ']]);
  const talk = await (await go('/clips/talk?since=4004')).text();
  const got = ids(talk);
  assert.equal(got.length, 2);
  assert.ok(Number(got[0]) < Number(got[1])); // 古い順(下に新しいのが来る)
  assert.match(talk, /ひとつめ[\s\S]*ふたつめ/);
  assert.doesNotMatch(talk, /<!doctype|<form class="room-write|<header class="timeline|<textarea|class="app-nav"/i); // 一枚ずつの <header class="clip-head"> は、クリップの一部

  // 続きから: 見えているところは、返さない
  assert.deepEqual(ids(await (await go(`/clips/talk?since=${got[0]}`)).text()), [got[1]]);

  // ピンの絞りこみ中は、新しい(ピンの無い)ものは、出ない
  assert.equal((await (await go('/clips/talk?since=4004&pinned=1')).text()).trim(), '');

  // 読めない since は、訊きかたが悪い
  assert.equal((await go('/clips/talk')).status, 400);
  assert.equal((await go('/clips/talk?since=abc')).status, 400);
});

// ── 呼び鈴 ────────────────────────────────────────────────────────

test('呼び鈴: 自分あての会話のぶんだけ、中身なしで鳴る', async () => {
  await reset();
  await talks(0);
  const bell = await openBell(`${BASE}/clips/stream`, { headers: { cookie: sid } });
  try {
    assert.equal(bell.res.status, 200);
    assert.match(bell.res.headers.get('content-type') ?? '', /^text\/event-stream/);
    assert.ok(await bell.until(/retry: 5000\n\n/));
    await talks(1);
    await mockPost('conversation?id=c1'); // ほかの部屋: 鳴らさない
    await mockPost('conversation?id=c0'); // 自分あて: 鳴る
    assert.ok(await bell.until(/event: poke\ndata: 1\n\n/));
    assert.equal(bell.text().match(/event: poke/g)?.length, 1);
    assert.doesNotMatch(bell.text(), /c0|c1/);
  } finally {
    bell.close();
  }
  await talks(0);
});

// ── 入っていない人 ──────────────────────────────────────────────────

test('入っていない人: 頁はログインへ。裏の口(取りなおし・呼び鈴)は、頁を追わせず 401', async () => {
  const out = await loggedOutServer(5254);
  try {
    const page = await fetch(`${out.base}/clips`, { redirect: 'manual' });
    assert.equal(page.status, 303);
    assert.match(page.headers.get('location') ?? '', /^\/login/);
    for (const path of ['/clips/talk?since=1', '/clips/stream']) {
      assert.equal((await fetch(`${out.base}${path}`, { redirect: 'manual' })).status, 401, path);
    }
    assert.equal((await fetch(`${out.base}/clips`, { redirect: 'manual', method: 'POST', body: new FormData() })).status, 303);
  } finally {
    out.stop();
  }
});
