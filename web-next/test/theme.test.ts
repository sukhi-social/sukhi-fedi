// SPDX-License-Identifier: AGPL-3.0-or-later
// 見た目のテーマ(SITE_THEME)。運営が about(既定)か ink(web の紙とインク)を選ぶ。
// 選ぶ道は server/theme.ts ひとつ。頁(<html data-theme>・theme-color・css の一行)と manifest が、同じ道を通る。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { THEMES, parseTheme, themedManifest } from '../server/theme.ts';

const css = (name: string) => readFileSync(new URL(`../public/css/${name}`, import.meta.url), 'utf8');

test('parseTheme: 知らない名前・空・大文字小文字', () => {
  assert.equal(parseTheme(undefined), 'about');
  assert.equal(parseTheme(''), 'about');
  assert.equal(parseTheme('ink'), 'ink');
  assert.equal(parseTheme('  INK '), 'ink');
  assert.equal(parseTheme('bogus'), 'about');
  // Object のもとから来る名前を、テーマと取りちがえない。
  assert.equal(parseTheme('constructor'), 'about');
  assert.equal(parseTheme('__proto__'), 'about');
});

test('themedManifest: 紙の色だけ替えて、ほかはそのまま。読めなければ手を入れない', () => {
  const raw = JSON.stringify({ name: 'sukhi', background_color: '#fffaf3', theme_color: '#fffaf3', icons: [{ src: '/icon-192.png' }] });
  const ink = JSON.parse(themedManifest(raw, 'ink'));
  assert.equal(ink.background_color, THEMES.ink.color.light);
  assert.equal(ink.theme_color, THEMES.ink.color.light);
  assert.equal(ink.name, 'sukhi');
  assert.deepEqual(ink.icons, [{ src: '/icon-192.png' }]);
  assert.equal(JSON.parse(themedManifest(raw, 'about')).theme_color, THEMES.about.color.light);
  assert.equal(themedManifest('{not json', 'ink'), '{not json');
});

// ink の css は、about の「色」を、ひとつ残らず替える(橙が、どこかから漏れてこない)。
function block(src: string, open: string): string {
  const at = src.indexOf(open);
  assert.ok(at >= 0, `${open} が見つからない`);
  const end = src.indexOf('\n}', at);
  return src.slice(at, end);
}
const names = (b: string) => new Set([...b.matchAll(/^\s*(--color-[\w-]+)\s*:/gm)].map((m) => m[1]));
// 暗い幕・画像の上の字は、パレットではなく、どのテーマでも同じ道具。
const isPalette = (n: string) => !/^--color-(scrim|on-scrim|border-fallback)/.test(n);

test('ink.css は、about の tokens の色を、ぜんぶ自分で決めている', () => {
  const about = [...names(block(css('tokens.css'), ':root {'))].filter(isPalette);
  const ink = names(block(css('theme-ink.css'), "html[data-theme='ink'] {"));
  assert.ok(about.length >= 14, `about の色の数 ${about.length}`);
  const missing = about.filter((n) => !ink.has(n));
  assert.deepEqual(missing, []);
});

test('ink.css のダークは、明るい側が「値」で決めた色を、ぜんぶ替える', () => {
  const src = css('theme-ink.css');
  const light = block(src, "html[data-theme='ink'] {");
  const literal = [...light.matchAll(/^\s*(--color-[\w-]+)\s*:\s*#/gm)].map((m) => m[1]);
  const dark = names(block(src, '@media (prefers-color-scheme: dark) {'));
  assert.deepEqual(literal.filter((n) => !dark.has(n)), []);
});

test('紙の色は、theme.ts と theme-ink.css で同じ(manifest は css の変数を読めない)', () => {
  const src = css('theme-ink.css');
  const bg = (b: string) => b.match(/--color-bg:\s*(#[0-9a-f]{6})/i)?.[1];
  assert.equal(bg(block(src, "html[data-theme='ink'] {")), THEMES.ink.color.light);
  assert.equal(bg(block(src, '@media (prefers-color-scheme: dark) {')), THEMES.ink.color.dark);
  assert.equal(bg(block(css('tokens.css'), ':root {')), THEMES.about.color.light);
  assert.equal(bg(block(css('tokens.css'), '@media (prefers-color-scheme: dark) {')), THEMES.about.color.dark);
});

async function withServer(port: number, env: Record<string, string>, body: (base: string) => Promise<void>): Promise<void> {
  const base = `http://localhost:${port}`;
  const child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: '', QUIET: '1', PORT: String(port), MOCK_PORT: String(port - 1000), PUBLIC_ORIGIN: base, ...env },
    stdio: 'ignore'
  });
  try {
    for (let i = 0; i < 50; i++) {
      try {
        if ((await fetch(`${base}/login`)).ok) break;
      } catch {
        // まだ立っていない。
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    await body(base);
  } finally {
    child.kill();
  }
}

test('SITE_THEME=ink: 頁・theme-color・manifest が、ink になる。css と字は配られる', async () => {
  await withServer(5240, { SITE_THEME: 'ink' }, async (base) => {
    const page = await (await fetch(`${base}/login`)).text();
    assert.match(page, /<html lang="[a-z]+" data-theme="ink">/);
    assert.match(page, /<link rel="stylesheet" href="\/assets\/css\/theme-ink\.css\?v=[0-9a-f]+" \/>/);
    assert.match(page, /<meta name="theme-color" content="#efeee7" media="\(prefers-color-scheme: light\)" \/>/);
    assert.match(page, /<meta name="theme-color" content="#1c1b18" media="\(prefers-color-scheme: dark\)" \/>/);
    // 上書きは、about の css のあとに読まれる。
    assert.ok(page.indexOf('theme-ink.css') > page.indexOf('/assets/css/extra.css'));

    const m = await fetch(`${base}/manifest.webmanifest`);
    assert.equal(m.status, 200);
    assert.match(m.headers.get('content-type') ?? '', /manifest\+json/);
    const manifest = await m.json();
    assert.equal(manifest.theme_color, '#efeee7');
    assert.equal(manifest.background_color, '#efeee7');
    assert.ok(Array.isArray(manifest.icons) && manifest.icons.length > 0);
    // 条件つき取得も効く。
    const again = await fetch(`${base}/manifest.webmanifest`, { headers: { 'if-none-match': m.headers.get('etag') ?? '' } });
    assert.equal(again.status, 304);

    const sheet = await fetch(`${base}/assets/css/theme-ink.css`);
    assert.equal(sheet.status, 200);
    assert.match(await sheet.text(), /html\[data-theme='ink'\]/);
    const font = await fetch(`${base}/assets/fonts-variable/source-sans-3/wght.css`);
    assert.equal(font.status, 200);
    assert.match(await font.text(), /Source Sans 3 Variable/);
  });
});

test('SITE_THEME が無い・知らない名前なら、これまでの about のまま(ink の css は、頁に付かない)', async () => {
  await withServer(5241, { SITE_THEME: 'bogus' }, async (base) => {
    const page = await (await fetch(`${base}/login`)).text();
    assert.match(page, /<html lang="[a-z]+" data-theme="about">/);
    assert.doesNotMatch(page, /theme-ink\.css/);
    assert.match(page, /<meta name="theme-color" content="#fffaf3" media="\(prefers-color-scheme: light\)" \/>/);
    const manifest = await (await fetch(`${base}/manifest.webmanifest`)).json();
    assert.equal(manifest.theme_color, '#fffaf3');
  });
});
