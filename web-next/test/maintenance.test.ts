// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { asItems, pickItems, plainText, renderMaintenancePage, MAX_ITEMS, type SnapItem } from '../server/maintenance.ts';
import { jaMaintenance, koMaintenance, enMaintenance } from '../server/locales/maintenance.ts';
import { LOCALES } from '../server/i18n.ts';

const status = (over: Record<string, unknown> = {}) => ({
  id: '1',
  visibility: 'public',
  content: '<p>こんにちは</p>',
  account: { acct: 'hina', username: 'hina', display_name: 'ひな' },
  ...over
});

test('本文は、段落を残した文字だけになる(タグも実体も、文字へ)', () => {
  assert.equal(plainText('<p>一行目<br>二行目</p><p>A &amp; B &lt;script&gt;</p>'), '一行目\n二行目\n\nA & B <script>');
  assert.equal(plainText('<p>a</p><p></p><p></p><p>b</p>'), 'a\n\nb');
  assert.equal(plainText('&#x1F600;&#39;&#0;&#xD800;&#99999999;'), '😀\'');
  assert.equal(plainText('<a href="javascript:alert(1)">link</a><img src=x onerror=alert(1)>'), 'link');
});

test('載せるのは、公開の、その人自身の投稿だけ', () => {
  const picked = pickItems([
    status(),
    status({ visibility: 'unlisted' }),
    status({ visibility: 'private' }),
    status({ visibility: 'direct' }),
    status({ reblog: status() }),
    status({ in_reply_to_id: '9' }),
    status({ quote: status() }),
    status({ content: '<p></p>' }),
    status({ account: { acct: '', display_name: 'x' } }),
    null,
    'not an object'
  ]);
  assert.equal(picked.length, 1);
  assert.deepEqual(picked[0], { name: 'ひな', acct: 'hina', text: 'こんにちは', fold: null, lang: null });
});

test('入力が配列でなくても落ちない', () => {
  assert.deepEqual(pickItems(undefined), []);
  assert.deepEqual(pickItems({ error: 'nope' }), []);
});

test('注意書き・センシティブは折りたたむ。独自絵文字の :name: は名前から外す', () => {
  const [cw, sens] = pickItems([
    status({ spoiler_text: '食べ物の話', content: '<p>ごはん</p>' }),
    status({ sensitive: true, account: { acct: 'a@b.example', display_name: ':blobcat: Nyan  Cat' } })
  ]);
  assert.equal(cw.fold, '食べ物の話');
  assert.equal(sens.fold, '');
  assert.equal(sens.name, 'Nyan Cat');
});

test('数は持ちこまない(お気に入り・ブースト)', () => {
  const [item] = pickItems([status({ favourites_count: 99, reblogs_count: 7, replies_count: 3 })]);
  assert.deepEqual(Object.keys(item).sort(), ['acct', 'fold', 'lang', 'name', 'text']);
});

test('件数と長さに上限がある', () => {
  const many = Array.from({ length: MAX_ITEMS + 20 }, (_, i) => status({ id: String(i) }));
  assert.equal(pickItems(many).length, MAX_ITEMS);
  const [long] = pickItems([status({ content: `<p>${'あ'.repeat(1000)}</p>` })]);
  assert.equal([...long.text].length, 401);
  assert.ok(long.text.endsWith('…'));
});

test('lang は形が正しいときだけ', () => {
  const [ok, bad] = pickItems([status({ language: 'ja' }), status({ language: '"><script>' })]);
  assert.equal(ok.lang, 'ja');
  assert.equal(bad.lang, null);
});

test('snapshot の JSON を読みなおすときも、形を信じない', () => {
  assert.deepEqual(asItems(null), []);
  assert.deepEqual(asItems({ items: 'x' }), []);
  const items = asItems({ items: [{ name: 'n', acct: 'a', text: 't', fold: null, lang: 'zz-top-secret-x' }, { acct: '', text: 't' }, { acct: 'a' }, 7] });
  assert.equal(items.length, 1);
  assert.equal(items[0].lang, null);
});

const evil: SnapItem = {
  name: '<img src=x onerror=alert(1)>',
  acct: 'a"><script>alert(1)</script>',
  text: '<script>alert(1)</script>\n\n"quote" & <b>bold</b>',
  fold: '<i>cw</i>',
  lang: 'ja'
};

test('頁は、外から来た文字をすべてエスケープする。script も外部ファイルも持たない', () => {
  for (const locale of LOCALES) {
    const page = renderMaintenancePage({ locale, siteName: '<b>site</b>', aboutUrl: 'https://about.example/x', items: [evil] });
    assert.doesNotMatch(page, /<script/i);
    assert.doesNotMatch(page, /<img/i);
    assert.doesNotMatch(page, /<b>/);
    assert.doesNotMatch(page, /<i>/);
    assert.match(page, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
    // 外のファイルを読まない(link rel=icon は data:)。
    assert.doesNotMatch(page, /(src|href)="https?:\/\/(?!about\.example)/);
    assert.doesNotMatch(page, /<link[^>]+rel="stylesheet"/);
    assert.match(page, new RegExp(`<html lang="${locale}">`));
    assert.match(page, /name="robots" content="noindex"/);
  }
});

test('リンクは http(s) だけ', () => {
  const page = renderMaintenancePage({ locale: 'ja', siteName: 's', aboutUrl: 'javascript:alert(1)' });
  assert.doesNotMatch(page, /javascript:/);
  assert.doesNotMatch(page, /class="about"/);
});

test('戻る見込みは、ゆるく言う。わからないときは、わからないと言う', () => {
  const page = (aboutMin?: number) => renderMaintenancePage({ locale: 'ja', siteName: 's', aboutMin });
  assert.match(page(30), /半刻ほどで戻る見込み/);
  assert.match(page(10), /約四半刻で戻る見込み/);
  assert.match(page(300), /すこし長くかかる/);
  assert.match(page(), /まだ決まっていません/);
  assert.match(page(0), /まだ決まっていません/);
  assert.match(page(Number.NaN), /まだ決まっていません/);
  assert.match(renderMaintenancePage({ locale: 'en', siteName: 's', aboutMin: 30 }), /in about half an hour/);
  assert.match(renderMaintenancePage({ locale: 'ko', siteName: 's', aboutMin: 30 }), /30분쯤 뒤에/);
});

test('時刻も数も出さない', () => {
  const page = renderMaintenancePage({ locale: 'ja', siteName: 's', aboutMin: 30, items: [{ ...evil, name: 'a', acct: 'a', text: 'x', fold: null }] });
  assert.doesNotMatch(page, /\d{1,2}:\d{2}/);
});

test('折りたたんだ投稿は details に入る。見出しが無ければ既定のことば', () => {
  const page = renderMaintenancePage({
    locale: 'en',
    siteName: 's',
    items: [
      { name: 'a', acct: 'a', text: 'hidden', fold: '', lang: null },
      { name: 'b', acct: 'b', text: 'spoiler', fold: 'food', lang: null }
    ]
  });
  assert.match(page, /<summary>Open if you’d like to read it<\/summary>/);
  assert.match(page, /<summary>food<\/summary>/);
});

test('一覧が無ければ、一覧の見出しも出さない', () => {
  const page = renderMaintenancePage({ locale: 'ja', siteName: 's', items: [] });
  assert.doesNotMatch(page, /止まる前の/);
});

test('ことばは三つの言語でそろい、差し込み口も同じ', () => {
  const slots = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(',');
  for (const [name, dict] of [['ko', koMaintenance], ['en', enMaintenance]] as const) {
    assert.deepEqual(Object.keys(dict).sort(), Object.keys(jaMaintenance).sort(), name);
    for (const k of Object.keys(jaMaintenance) as (keyof typeof jaMaintenance)[]) {
      assert.ok(dict[k], `${name} ${k}`);
      assert.equal(slots(dict[k]), slots(jaMaintenance[k]), `${name} ${k}`);
    }
  }
});

// ── 道具(CLI)。偽の gateway を立てて、snapshot → render を通す ──────────

const cli = new URL('../server/maintenance-cli.ts', import.meta.url).pathname;
const run = (args: string[], input: string, env: Record<string, string> = {}) =>
  spawnSync(process.execPath, [cli, ...args], { input, encoding: 'utf8', env: { ...process.env, ...env } });

test('CLI: render は stdin の snapshot から頁を作る。壊れた stdin でも頁は出る', () => {
  const snap = JSON.stringify({ items: [{ name: 'ひな', acct: 'hina', text: 'ふむ', fold: null, lang: null }] });
  const ok = run(['render', '--lang', 'ko', '--why', 'backup', '--about', '30'], snap);
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, /<html lang="ko">/);
  assert.match(ok.stdout, /ふむ/);
  assert.match(ok.stdout, /백업/);

  const broken = run(['render', '--lang', 'ja'], '{not json');
  assert.equal(broken.status, 0);
  assert.match(broken.stdout, /メンテナンス中です/);
  assert.doesNotMatch(broken.stdout, /止まる前の/);
});

test('CLI: 引数が違えば、頁を出さずに 2 で終わる', () => {
  assert.equal(run(['render', '--lang', 'fr'], '').status, 2);
  assert.equal(run(['render', '--lang', 'ja', '--why', 'because'], '').status, 2);
  assert.equal(run(['render', '--lang', 'ja', '--about', 'soon'], '').status, 2);
  assert.equal(run(['nope'], '').status, 2);
});

test('CLI: snapshot は gateway から公開投稿を選ぶ。取れなければ空で 3', async () => {
  const { createServer } = await import('node:http');
  let seen = '';
  const server = createServer((req, res) => {
    seen = `${req.url} auth=${req.headers.authorization ?? '-'} cookie=${req.headers.cookie ?? '-'}`;
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify([status(), status({ visibility: 'private' })]));
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as { port: number }).port;
  try {
    const { spawn } = await import('node:child_process');
    const go = (gateway: string) =>
      new Promise<{ code: number | null; out: string }>((resolve) => {
        const child = spawn(process.execPath, [cli, 'snapshot'], { env: { ...process.env, GATEWAY_URL: gateway } });
        let out = '';
        child.stdout.on('data', (d) => (out += d));
        child.on('close', (code) => resolve({ code, out }));
      });

    const good = await go(`http://127.0.0.1:${port}`);
    assert.equal(good.code, 0);
    assert.equal(JSON.parse(good.out).items.length, 1);
    assert.match(seen, /^\/api\/v1\/timelines\/public\?local=1&/);
    assert.match(seen, /auth=- cookie=-$/);

    const down = await go('http://127.0.0.1:1');
    assert.equal(down.code, 3);
    assert.deepEqual(JSON.parse(down.out), { items: [] });
  } finally {
    server.close();
  }
});
