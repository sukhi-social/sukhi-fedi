// UX 契約(docs/UX_CONTRACT.md)の動作確認。
//
//   pnpm run ux-check          # build してから
//
// 実際の Chrome を、macOS / Windows / Android の姿(userAgent と端末)で
// 動かして、窓とメニューの閉じかた、戻る、⌘/Ctrl+Enter、タップの大きさを
// 見る。API は shots/mock.mjs が受け取る(箱もサーバも要らない)。
// Chrome が無ければ、Playwright の Chromium を使う。
// 最後の「under 44px」の棚卸しは合否ではなく、いま残っている小さな対象の
// 一覧(文中のリンクは WCAG 2.5.8 の例外なので除く)。

import path from 'node:path';
import { chromium, devices } from '@playwright/test';
import { installMocks, HOME } from './mock.mjs';
import { serveBuild } from './serve.mjs';

const WEB = process.cwd();
const PORT = 4181;
const BASE = `http://127.0.0.1:${PORT}`;
const server = await serveBuild(path.join(WEB, 'build'), PORT);
const browser = await chromium
  .launch({ channel: 'chrome', headless: true })
  .catch(() => chromium.launch({ headless: true }));

const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
};

const MAC_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
const WIN_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

// 画像つきの投稿を一件まぜた home
const homeWithImage = () => {
  const rows = structuredClone(HOME);
  rows[0].media_attachments = [
    { id: 'm1', type: 'image', url: '/avatar-default.svg', preview_url: '/avatar-default.svg', description: 'test' }
  ];
  return rows;
};

async function open(context, url) {
  const page = await context.newPage();
  const unknown = new Set();
  const posts = [];
  await installMocks(page, { lang: 'ja', signedIn: true }, unknown);
  await page.route('**/api/v1/timelines/home**', (r) =>
    r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(homeWithImage()) })
  );
  page.on('request', (req) => {
    if (req.method() === 'POST' && /\/api\/v1\/statuses$/.test(new URL(req.url()).pathname)) posts.push(req.postData());
  });
  page.on('pageerror', (e) => console.log('  pageerror:', e.message));
  await page.goto(`${BASE}/`);
  await page.waitForLoadState('networkidle');
  return { page, posts };
}

async function tapMin(page) {
  return page.evaluate(() => {
    const d = document.createElement('div');
    d.style.cssText = 'position:absolute;visibility:hidden;min-height:var(--tap-min)';
    document.body.append(d);
    const v = parseFloat(getComputedStyle(d).minHeight);
    d.remove();
    return v;
  });
}

async function runDesktop(label, ua, modPress, wrongPress, expectPlatform) {
  const context = await browser.newContext({ userAgent: ua, viewport: { width: 1280, height: 900 } });
  const { page, posts } = await open(context);
  const L = (s) => `[${label}] ${s}`;

  const plat = await page.evaluate(() => document.documentElement.dataset.platform);
  const uad = await page.evaluate(() => navigator.userAgentData?.platform ?? '(none)');
  check(L(`data-platform = ${expectPlatform}`), plat === expectPlatform, `got ${plat}, userAgentData.platform=${uad}`);
  check(L('--tap-min = 44px'), (await tapMin(page)) === 44, String(await tapMin(page)));

  // ── タイムラインへ(クライアント遷移で履歴 '/' → '/timeline')
  await page.goto(`${BASE}/timeline`);
  await page.waitForSelector('.status-actions', { timeout: 8000 });

  // メニュー: ブースト
  const boost = page.locator('.status-actions .boost-wrap > button').first();
  await boost.click();
  check(L('boost menu opens'), await page.locator('.boost-menu').first().isVisible());
  await page.keyboard.press('Escape');
  check(L('boost menu: Esc closes'), !(await page.locator('.boost-menu').count()));
  await boost.click();
  await page.mouse.click(5, 450);
  check(L('boost menu: outside click closes'), !(await page.locator('.boost-menu').count()));
  await boost.click();
  await boost.click();
  check(L('boost menu: trigger toggles closed (not reopen)'), !(await page.locator('.boost-menu').count()));

  // メニュー: …(more)
  const more = page.locator('.status-actions button[aria-haspopup="menu"]').nth(1);
  await more.click();
  check(L('more menu opens'), (await page.locator('.menu[role=menu]:not(.boost-menu)').count()) === 1);
  await more.click();
  check(L('more menu: trigger toggles closed'), (await page.locator('.menu[role=menu]:not(.boost-menu)').count()) === 0);
  await more.click();
  await page.keyboard.press('Escape');
  check(L('more menu: Esc closes'), (await page.locator('.menu[role=menu]:not(.boost-menu)').count()) === 0);
  await more.click();
  await page.mouse.click(5, 450);
  check(L('more menu: outside click closes'), (await page.locator('.menu[role=menu]:not(.boost-menu)').count()) === 0);

  // フィルター(タイムライン)
  const filter = page.locator('.filter-bar > button').first();
  if (await filter.count()) {
    await filter.click();
    const open1 = await page.locator('.filter-menu').count();
    await page.keyboard.press('Escape');
    check(L('timeline filter: opens then Esc closes'), open1 === 1 && (await page.locator('.filter-menu').count()) === 0);
  }

  // ── 拡大表示: Esc(履歴の位置は Navigation API の index で数える)
  const idx = () => page.evaluate(() => navigation.currentEntry.index);
  const before = page.url();
  const i0 = await idx();
  await page.locator('.media img').first().click();
  check(L('lightbox opens'), await page.locator('.lightbox').isVisible());
  check(L('lightbox: URL unchanged'), page.url() === before);
  await page.waitForTimeout(200);
  const i1 = await idx();
  check(L('lightbox: adds exactly one history entry'), i1 === i0 + 1, `index ${i0} -> ${i1}`);
  await page.keyboard.press('Escape');
  await page.waitForTimeout(400);
  check(L('lightbox: Esc closes'), !(await page.locator('.lightbox').count()));
  const i2 = await idx();
  check(L('Esc-close takes the added entry back (no phantom entry)'), i2 === i0, `index ${i1} -> ${i2}`);

  // ── 拡大表示: 戻る
  await page.locator('.media img').first().click();
  check(L('lightbox opens again'), await page.locator('.lightbox').isVisible());
  await page.goBack();
  await page.waitForTimeout(300);
  check(L('lightbox: Back closes it'), !(await page.locator('.lightbox').count()));
  check(L('lightbox: Back stays on /timeline'), new URL(page.url()).pathname === '/timeline', page.url());

  // ── ⌘/Ctrl+Enter で投稿
  await page.goto(`${BASE}/compose`);
  const ta = page.locator('textarea').first();
  await ta.waitFor({ timeout: 8000 });
  await ta.fill('こんにちは');
  const ks = await page.locator('button[type=submit][aria-keyshortcuts]').first().getAttribute('aria-keyshortcuts');
  check(L('submit has aria-keyshortcuts'), ks === (expectPlatform === 'mac' ? 'Meta+Enter' : 'Control+Enter'), String(ks));
  const n0 = posts.length;
  await ta.press(wrongPress);
  await page.waitForTimeout(300);
  check(L(`${wrongPress} does NOT post`), posts.length === n0);
  await ta.press(modPress);
  await page.waitForTimeout(500);
  check(L(`${modPress} posts`), posts.length === n0 + 1, `posts=${posts.length - n0}`);

  await context.close();
}


// 指で押す行の、押せる領域(::after)を測る。::after は position:absolute で、
// 中心は chip の中心(left/top 50% + translate -50%)。
async function hitAreas(page) {
  return page.evaluate(() => {
    const tap = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--tap-min')) * 16 || 44;
    const rects = [];
    for (const el of document.querySelectorAll('.status-actions .chip, .status-actions ~ .reactions .reaction-chip, .reactions .reaction-chip')) {
      const b = el.getBoundingClientRect();
      if (!b.width) continue;
      const cs = getComputedStyle(el, '::after');
      const w = parseFloat(cs.width) || b.width;
      const h = parseFloat(cs.height) || b.height;
      const cx = b.left + b.width / 2, cy = b.top + b.height / 2;
      rects.push({ el, l: cx - w / 2, r: cx + w / 2, t: cy - h / 2, b: cy + h / 2, w, h });
    }
    const name = (e) => `${e.tagName.toLowerCase()}.${[...e.classList].slice(0, 2).join('.')}`;
    const overlaps = [];
    for (let i = 0; i < rects.length; i++) {
      for (let j = i + 1; j < rects.length; j++) {
        const a = rects[i], c = rects[j];
        const ox = Math.min(a.r, c.r) - Math.max(a.l, c.l);
        const oy = Math.min(a.b, c.b) - Math.max(a.t, c.t);
        if (ox > 0.5 && oy > 0.5) overlaps.push(`${name(a.el)} x ${name(c.el)} (${ox.toFixed(1)}x${oy.toFixed(1)}px)`);
      }
    }
    const vw = document.documentElement.clientWidth;
    const overflow = [];
    for (const f of document.querySelectorAll('.status-actions')) {
      const fr = f.getBoundingClientRect();
      for (const c of f.querySelectorAll('.chip')) {
        const r = c.getBoundingClientRect();
        if (r.right > fr.right + 0.5) overflow.push(`chip right=${r.right.toFixed(0)} > row right=${fr.right.toFixed(0)}`);
      }
    }
    for (const r of rects) {
      if (r.l < -0.5 || r.r > vw + 0.5) overflow.push(`hit area ${r.l.toFixed(0)}..${r.r.toFixed(0)} outside the ${vw}px screen`);
    }
    return { tap, count: rects.length, minHit: Math.round(Math.min(...rects.map((r) => Math.min(r.w, r.h))) * 10) / 10, overlaps, overflow };
  });
}

async function runAndroid() {
  const context = await browser.newContext({ ...devices['Pixel 7'] });
  const { page } = await open(context);
  const L = (s) => `[android] ${s}`;

  const plat = await page.evaluate(() => document.documentElement.dataset.platform);
  const uad = await page.evaluate(() => navigator.userAgentData?.platform ?? '(none)');
  check(L('data-platform = android'), plat === 'android', `got ${plat}, userAgentData.platform=${uad}`);
  check(L('--tap-min = 48px'), (await tapMin(page)) === 48, String(await tapMin(page)));

  await page.goto(`${BASE}/timeline`);
  await page.waitForSelector('.status-actions', { timeout: 8000 });

  // 指で押す行 ── 見える大きさと、指が拾う大きさは別。拾う側(::after)が
  // --tap-min に届き、重ならず、列が溢れないこと。幅は 412(Pixel 7)と、
  // より狭い 375 / 360 で。
  for (const width of [412, 375, 360]) {
    await page.setViewportSize({ width, height: 800 });
    await page.waitForTimeout(150);
    const m = await hitAreas(page);
    const W = `${width}px`;
    check(L(`${W}: action targets found`), m.count > 0, `count=${m.count}`);
    check(L(`${W}: hit area >= --tap-min (${m.tap}px)`), m.minHit >= m.tap - 0.5, `min=${m.minHit}`);
    check(L(`${W}: hit areas do not overlap`), m.overlaps.length === 0, m.overlaps.slice(0, 3).join(' | '));
    check(L(`${W}: action row does not overflow`), m.overflow.length === 0, m.overflow.slice(0, 3).join(' | '));
  }
  await page.setViewportSize({ width: 412, height: 915 });
  await page.waitForTimeout(150);

  // 貼り付いた屋根が、画面を食いすぎない(中の操作 + 上下 4px ずつ。72px → 56px)。
  const navH = await page.evaluate(() => Math.round(document.querySelector('header.app-nav').getBoundingClientRect().height));
  check(L('top bar <= 58px (tap-min + 8 + border)'), navH <= 58, `height=${navH}`);

  // 拡大 → 戻る
  await page.locator('.media img').first().tap();
  check(L('lightbox opens (tap)'), await page.locator('.lightbox').isVisible());
  await page.goBack();
  await page.waitForTimeout(300);
  check(L('Back closes lightbox'), !(await page.locator('.lightbox').count()));
  check(L('Back stays on /timeline'), new URL(page.url()).pathname === '/timeline', page.url());

  // 小さな対象の棚卸し(文中リンクは WCAG の例外なので除く)
  for (const p of ['/timeline', '/compose', '/notifications', '/search?q=x', '/settings', '/messages']) {
    await page.goto(`${BASE}${p}`);
    await page.waitForTimeout(700);
    const small = await page.evaluate(() => {
      const out = [];
      const sel = 'button, a[href], input:not([type=hidden]):not([type=checkbox]):not([type=radio]), select, textarea, [role=button], [role=menuitem]';
      for (const el of document.querySelectorAll(sel)) {
        const r = el.getBoundingClientRect();
        if (!r.width || !r.height) continue;
        // 文中のリンク(段落・本文の中の a)
        if (el.tagName === 'A' && el.closest('p, li, .body, .status-content, .profile-note, dd, h1, h2, h3')) continue;
        if (el.classList.contains('visually-hidden') || el.closest('.visually-hidden')) continue;
        const ph = parseFloat(getComputedStyle(el, '::after').height) || 0;
        const pw = parseFloat(getComputedStyle(el, '::after').width) || 0;
        const hitH = Math.max(r.height, ph), hitW = Math.max(r.width, pw);
        if (hitH < 44 || hitW < 44) {
          out.push(`${el.tagName.toLowerCase()}.${[...el.classList].join('.')} ${Math.round(r.width)}x${Math.round(r.height)} "${(el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 18)}"`);
        }
      }
      return out;
    });
    console.log(`  [android] ${p}: ${small.length} target(s) under 44px`);
    for (const s of small.slice(0, 12)) console.log('     ' + s);
  }
  await context.close();
}

try {
  await runDesktop('mac', MAC_UA, 'Meta+Enter', 'Control+Enter', 'mac');
  await runDesktop('windows', WIN_UA, 'Control+Enter', 'Meta+Enter', 'windows');
  await runAndroid();
} finally {
  await browser.close();
  server.close();
}

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
if (failed.length) {
  console.log('FAILED:');
  for (const f of failed) console.log('  - ' + f.name + (f.detail ? ' — ' + f.detail : ''));
  process.exitCode = 1;
}
