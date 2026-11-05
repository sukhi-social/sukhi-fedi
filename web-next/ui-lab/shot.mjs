// SPDX-License-Identifier: AGPL-3.0-or-later
// モックの写真を撮る。目で見て比べるための道具。依存は playwright だけ(入っていれば使う)。
//
//   node shot.mjs <id> [<id> …]                     一枚ずつ、頁の全部を
//   node shot.mjs --compare <A> <B>                 ギャラリーと同じ並びで、A と B を横に
//
//   --device phone,desktop   (既定 phone,desktop)   phone=390×844 tablet=768×1024 desktop=1100×820
//   --theme  light,dark      (既定 light)
//   --scene  fresh,night     場面(モックの lab:scenes)。--compare では A にだけ。--sceneB で B に
//   --now    22:30           時計(native のモックだけ)
//   --out    <dir>           (既定 ./shots)
//   --no-full                頁の全部ではなく、画面ぶんだけ
//
// <id> は、ギャラリーの一覧に出る名前。動いている web-next は live:/ のように、live: をつけた道。
// 先に `node serve.mjs` を立てておく(LAB=http://localhost:5180)。live を撮るなら `pnpm run dev:mock`(:5174)も。

import { mkdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';

const LAB = process.env.LAB ?? 'http://localhost:5180';
const DEVICES = { phone: [390, 844], tablet: [768, 1024], desktop: [1100, 820] };

// ESM は NODE_PATH を見ない。あちこちから探す。
function loadPlaywright() {
  const here = createRequire(import.meta.url);
  const roots = [undefined, ...(process.env.NODE_PATH ?? '').split(':').filter(Boolean), '/opt/node-tools/node_modules'];
  for (const r of roots) {
    try {
      return (r ? createRequire(join(r, 'x.js')) : here)('playwright');
    } catch {}
  }
  console.error('playwright が見つかりません。(pnpm add -D playwright か、NODE_PATH で)');
  process.exit(1);
}

const argv = process.argv.slice(2);
const opt = { device: 'phone,desktop', theme: 'light', out: 'shots', scene: '', sceneB: '', now: '', full: true };
const targets = [];
let compare = false;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--compare') compare = true;
  else if (a === '--no-full') opt.full = false;
  else if (a.startsWith('--')) opt[a.slice(2)] = argv[++i];
  else targets.push(a);
}
if (!targets.length || (compare && targets.length !== 2)) {
  console.error('使いかた: node shot.mjs <id>…  /  node shot.mjs --compare <A> <B>   (くわしくは先頭のコメント)');
  process.exit(2);
}

const mocks = await (await fetch(`${LAB}/_lab/mocks.json`)).json();
const byId = (id) => {
  const m = mocks.find((x) => x.id === id);
  if (!m) throw new Error(`「${id}」はありません。あるのは: ${mocks.map((x) => x.id).join(', ')}`);
  return m;
};
const safe = (s) => s.replace(/[^a-z0-9]+/gi, '_').replace(/^_|_$/g, '');
const devices = opt.device.split(',');
const themes = opt.theme.split(',');
mkdirSync(opt.out, { recursive: true });

const { chromium } = loadPlaywright();
const browser = await chromium.launch();

async function settle(page) {
  await page.waitForLoadState('load').catch(() => {});
  await page.evaluate(() => document.fonts?.ready).catch(() => {});
  await page.waitForTimeout(700); // 字の着替え・Alpine・React が落ちつくぶん
}

for (const theme of themes) {
  for (const dev of devices) {
    const [w, h] = DEVICES[dev];
    if (compare) {
      const [a, b] = targets.map(byId);
      const ctx = await browser.newContext({ viewport: { width: w * 2, height: h }, colorScheme: theme });
      const page = await ctx.newPage();
      const q = new URLSearchParams({ a: a.id, b: b.id, d: dev, t: theme, bare: '1' });
      if (opt.scene) q.set('sa', opt.scene);
      if (opt.sceneB) q.set('sb', opt.sceneB);
      if (opt.now) q.set('now', opt.now);
      await page.goto(`${LAB}/#${q}`);
      await page.waitForSelector('iframe');
      await settle(page);
      await page.waitForTimeout(800);
      const file = join(opt.out, `compare-${safe(a.id)}-vs-${safe(b.id)}-${dev}-${theme}.png`);
      await page.screenshot({ path: file });
      console.log(file);
      await ctx.close();
      continue;
    }
    for (const id of targets) {
      const m = byId(id);
      const ctx = await browser.newContext({ viewport: { width: w, height: h }, colorScheme: theme, deviceScaleFactor: 1 });
      const page = await ctx.newPage();
      const url = new URL(m.url, LAB);
      if (m.kind === 'native') {
        if (opt.scene) url.searchParams.set('s', opt.scene);
        if (opt.now) url.searchParams.set('now', opt.now);
      }
      await page.goto(url.href);
      await settle(page);
      const file = join(opt.out, `${safe(m.id)}${opt.scene ? '@' + safe(opt.scene) : ''}-${dev}-${theme}.png`);
      await page.screenshot({ path: file, fullPage: opt.full });
      console.log(file);
      await ctx.close();
    }
  }
}
await browser.close();
