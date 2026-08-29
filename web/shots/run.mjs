// sukhi の画面を、ぜんぶ絵にする。
//
//   npm run shots                     # ja/ko、全ページ
//   npm run shots -- --only timeline  # 一枚だけ撮り直す
//   npm run shots -- --langs ko       # 韓国語だけ
//   npm run shots -- --mobile         # 細い画面で
//
// 箱もサーバも要らない ── build したものを shots/serve.mjs で出して、
// API は shots/mock.mjs が途中で受け取る。時計も止めてあるので、同じ
// コードなら何度撮っても同じ絵になる。
//
// (web-natadeco/shots にも同じ形のものが在る。二つは別の package で、
//  撮る画面も口も違うので、まとめずにそれぞれ持たせている。)

import { chromium } from 'playwright';
import { mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { installMocks } from './mock.mjs';
import { serveBuild } from './serve.mjs';

const PORT = 4175;
const BASE = `http://127.0.0.1:${PORT}`;
const BUILD = path.resolve('build');

// ── どの画面を撮るか ──────────────────────────────────────────────
//
// 人が歩く順。玄関 → 入る/はじめる → 中の暮らし → 設定、の並びに
// してあるので、出力のフォルダを上から見ると、そのまま案内になる。

const PAGES = [
  { name: 'landing', path: '/', signedIn: false },
  { name: 'invite', path: '/invite/warm-code', signedIn: false },
  { name: 'signup', path: '/signup', signedIn: false },
  {
    name: 'check-signup',
    path: '/check?intent=signup',
    signedIn: false,
    seed: {
      'sf.signup_draft': JSON.stringify({ username: 'kuro', email: 'kuro@example.com', invite_code: 'warm-code' })
    }
  },
  { name: 'login', path: '/login', signedIn: false },
  {
    name: 'check-login-email',
    path: '/check?intent=login-email',
    signedIn: false,
    seed: { 'sf.login_email': 'kuro@example.com' }
  },
  { name: 'callback-failed', path: '/app/callback', signedIn: false },
  { name: 'timeline', path: '/timeline' },
  { name: 'notifications', path: '/notifications' },
  { name: 'compose', path: '/compose' },
  { name: 'search', path: '/search?q=%E3%81%8A%E8%8C%B6' },
  { name: 'profile', path: '/@kuro' },
  { name: 'note', path: '/@nabi/1002' },
  { name: 'followers', path: '/@kuro/followers' },
  { name: 'following', path: '/@kuro/following' },
  { name: 'article', path: '/articles/2001' },
  { name: 'tag', path: '/tags/ochado' },
  { name: 'lists', path: '/lists' },
  { name: 'list', path: '/lists/1' },
  { name: 'messages', path: '/messages' },
  { name: 'message', path: '/messages/c1' },
  { name: 'clips', path: '/clips' },
  { name: 'bookmarks', path: '/bookmarks' },
  { name: 'favourites', path: '/favourites' },
  { name: 'requests', path: '/requests' },
  { name: 'map', path: '/map' },
  { name: 'settings', path: '/settings' },
  { name: 'settings-security', path: '/settings/security' },
  { name: 'settings-password', path: '/settings/password' },
  { name: 'settings-migration', path: '/settings/migration' },
  { name: 'settings-cleanup', path: '/settings/cleanup' }
];

// ── 引数 ──────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const has = (name) => argv.includes(`--${name}`);

const langs = flag('langs', 'ja,ko').split(',');
const only = flag('only', null);
const outRoot = path.resolve(flag('out', 'shots/out'));
const viewport = has('mobile') ? { width: 390, height: 844 } : { width: 1280, height: 900 };

const pages = only ? PAGES.filter((p) => p.name === only) : PAGES;
if (!pages.length) {
  console.error(`--only ${only}: そんな名前の画面はありません`);
  console.error(`ある名前: ${PAGES.map((p) => p.name).join(', ')}`);
  process.exit(1);
}

// ── build/ を出す ────────────────────────────────────────────────

const server = await serveBuild(BUILD, PORT);
const stopServer = () => server.close();
process.on('SIGINT', () => {
  stopServer();
  process.exit(130);
});

// ── 撮る ──────────────────────────────────────────────────────────

const unknown = new Set();
const broken = [];
const restless = [];
let taken = 0;

try {
  // 一枚だけ撮り直すときは、前の絵を消さない ── `--only` は撮り直しの
  // ための旗なので、それで他の 60 枚が消えては困る。
  if (!only) await rm(outRoot, { recursive: true, force: true });

  const browser = await chromium.launch();

  for (const lang of langs) {
    const dir = path.join(outRoot, lang);
    await mkdir(dir, { recursive: true });

    for (const spec of pages) {
      const context = await browser.newContext({
        viewport,
        locale: lang === 'ko' ? 'ko-KR' : 'ja-JP',
        deviceScaleFactor: 2
      });
      const page = await context.newPage();

      const errors = [];
      page.on('pageerror', (e) => errors.push(String(e)));
      page.on('console', (m) => {
        if (m.type() === 'error') errors.push(m.text());
      });

      await installMocks(page, { lang, signedIn: spec.signedIn, seed: spec.seed }, unknown);

      const label = `${lang}/${spec.name}`;
      try {
        await page.goto(BASE + spec.path, { waitUntil: 'domcontentloaded', timeout: 20_000 });
        // 落ち着くまで待つ。落ち着かない画面(ずっと何かを聞いている)でも
        // 絵は撮る ── 撮れないより、撮れたうえで「落ち着かなかった」と
        // 言うほうがいい。
        try {
          await page.waitForLoadState('networkidle', { timeout: 8_000 });
        } catch {
          restless.push(label);
        }
        if (spec.act) await spec.act(page);
        // 絵文字の差し替えや画像の到着を待つ、ひと呼吸。
        await page.waitForTimeout(300);

        const n = String(PAGES.indexOf(spec) + 1).padStart(2, '0');
        await page.screenshot({ path: path.join(dir, `${n}-${spec.name}.png`), fullPage: true });
        taken += 1;
        process.stdout.write(`  ${label}\n`);
      } catch (e) {
        broken.push(`${label}: ${e.message.split('\n')[0]}`);
        process.stdout.write(`  ${label}  ← 撮れませんでした\n`);
      }

      if (errors.length) broken.push(`${label}: ${errors[0]}`);

      await context.close();
    }
  }

  await browser.close();
} finally {
  stopServer();
}

// ── 報告 ──────────────────────────────────────────────────────────

console.log(`\n${taken} 枚: ${outRoot}`);

if (unknown.size) {
  console.log('\nmock が知らなかった口(空の [] を返しました):');
  for (const u of [...unknown].sort()) console.log(`  ${u}`);
  console.log('  → shots/mock.mjs の ROUTES に足すと、その画面に中身が入ります');
}

if (restless.length) {
  console.log('\n落ち着かなかった画面(絵は撮れています。何かを聞きつづけています):');
  for (const r of restless) console.log(`  ${r}`);
}

if (broken.length) {
  console.log('\nうまく出なかったところ:');
  for (const b of broken) console.log(`  ${b}`);
  process.exitCode = 1;
}
