// natadeco の画面を、ぜんぶ絵にする。
//
//   npm run shots                     # ja/ko × light/dark、全ページ
//   npm run shots -- --only login     # 一枚だけ撮り直す
//   npm run shots -- --langs ko       # 韓国語だけ
//   npm run shots -- --mobile         # 細い画面で
//
// 箱もサーバも要らない ── build したものを `vite preview` で出して、
// API は shots/mock.mjs が途中で受け取る。時計も止めてあるので、
// 同じコードなら何度撮っても同じ絵になる(差分で見られる)。
//
// うまく出なかったページは最後にまとめて言う。**黙って空の絵を残さない**
// ── ドキュメントに使う一枚が、実は真っ白だった、が起こらないように。

import { chromium } from 'playwright';
import { mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { installMocks } from './mock.mjs';
import { serveBuild } from './serve.mjs';

const PORT = 4174;
const BASE = `http://127.0.0.1:${PORT}`;
const BUILD = path.resolve('build');

// ── どの画面を撮るか ──────────────────────────────────────────────
//
// 番号は並び順(ファイル名の頭に付く)。人が歩く順に並べてあるので、
// 出力のフォルダを上から見ると、そのまま案内になる。

const PAGES = [
  { name: 'hello', path: '/hello', signedIn: false },
  { name: 'signup', path: '/signup', signedIn: false },
  {
    name: 'check-signup',
    path: '/check?intent=signup',
    signedIn: false,
    // 関所の向こう。下書きを持って来た人が見る、コードを待つ画面。
    seed: {
      'nd.signup_draft': JSON.stringify({ username: 'hinata', email: 'hinata@example.com' })
    }
  },
  { name: 'login', path: '/login', signedIn: false },
  {
    name: 'check-login-email',
    path: '/check?intent=login-email',
    signedIn: false,
    seed: { 'nd.login_email': 'hinata@example.com' }
  },
  { name: 'callback-failed', path: '/app/callback', signedIn: false },
  { name: 'decos', path: '/' },
  { name: 'deco-thread', path: '/d/chai' },
  { name: 'deco-talk', path: '/d/yoru' },
  { name: 'deco-new', path: '/d/chai/new' },
  { name: 'post', path: '/posts/101' },
  { name: 'tomo', path: '/tomo' },
  { name: 'person', path: '/people/2' },
  { name: 'veranda-empty', path: '/veranda' },
  {
    name: 'veranda',
    path: '/veranda',
    // 手すりの向こうが見えている状態。空の入力欄だけでは、この場所が
    // 何をするところか絵から分からないので。
    act: async (page) => {
      await page.fill('input[type="search"]', '@engawa@example.social');
      await page.click('form.find button[type="submit"]');
      await page.waitForSelector('section.who', { timeout: 5000 });
    }
  },
  { name: 'notifications', path: '/notifications' },
  { name: 'settings', path: '/settings' },
  { name: 'settings-security', path: '/settings/security' },
  {
    name: 'settings-security-rename',
    path: '/settings/security',
    // 鍵の名前を書き直しているところ。欄が鍵の下に開く形を、絵に残す。
    act: async (page) => {
      await page.click('.keys li:first-child button:has-text("名前を変える"), .keys li:first-child button:has-text("이름 바꾸기")');
      await page.waitForSelector('form.edit', { timeout: 5000 });
    }
  },
  { name: 'about', path: '/about', signedIn: false }
];

// ── 引数 ──────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const has = (name) => argv.includes(`--${name}`);

const langs = flag('langs', 'ja,ko').split(',');
const themes = flag('themes', 'light,dark').split(',');
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
    for (const theme of themes) {
      const dir = path.join(outRoot, `${lang}-${theme}`);
      await mkdir(dir, { recursive: true });

      for (const [i, spec] of pages.entries()) {
        const context = await browser.newContext({
          viewport,
          locale: lang === 'ko' ? 'ko-KR' : 'ja-JP',
          colorScheme: theme,
          deviceScaleFactor: 2
        });
        const page = await context.newPage();

        const errors = [];
        page.on('pageerror', (e) => errors.push(String(e)));
        page.on('console', (m) => {
          if (m.type() === 'error') errors.push(m.text());
        });

        await installMocks(page, { lang, theme, signedIn: spec.signedIn, seed: spec.seed }, unknown);

        const label = `${lang}-${theme}/${spec.name}`;
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
          await page.screenshot({
            path: path.join(dir, `${n}-${spec.name}.png`),
            fullPage: true
          });
          taken += 1;
          process.stdout.write(`  ${label}\n`);
        } catch (e) {
          broken.push(`${label}: ${e.message.split('\n')[0]}`);
          process.stdout.write(`  ${label}  ← 撮れませんでした\n`);
        }

        // 画面の中で本当に落ちていたら、絵は撮れていても言う。
        if (errors.length) broken.push(`${label}: ${errors[0]}`);

        await context.close();
        void i;
      }
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
