// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 二つの絵の置き場(pnpm run shots -- --out DIR で撮ったもの)を比べて、見た目が
// 動いた画面を出す。CSS を安全に直すための網:
//
//   pnpm run shots -- --out /tmp/a            # 直す前
//   (CSS を直す)
//   pnpm run shots -- --out /tmp/b            # 直した後
//   node shots/compare.mjs /tmp/a /tmp/b      # 動いた画面だけ出る(何も出なければ同じ)
//
// 同じコードで二度撮っても、文字の縁の濃淡と、動く図(地図)で、すこし揺れる。
// そこは「色の差が大きい画素(3 色の差の和が 90 を超える)」だけを数えて、
// 揺れを無視する。n が数十を超えたり、大きさ(size)が変わったら、本物の変化。

import { chromium } from '@playwright/test';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, relative } from 'node:path';

const [A, B] = process.argv.slice(2);
const walk = (d, o = []) => {
  for (const n of readdirSync(d)) {
    const p = join(d, n);
    statSync(p).isDirectory() ? walk(p, o) : n.endsWith('.png') && o.push(p);
  }
  return o;
};
const md5 = (p) => createHash('md5').update(readFileSync(p)).digest('hex');

const diffs = [];
for (const a of walk(A)) {
  const rel = relative(A, a);
  const b = join(B, rel);
  try {
    if (md5(a) !== md5(b)) diffs.push(rel);
  } catch {
    diffs.push(rel + ' (missing)');
  }
}
if (!diffs.length) {
  console.log('identical');
  process.exit(0);
}
const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage();
await page.setContent('<canvas id=c></canvas>');
for (const rel of diffs) {
  if (rel.includes('(missing)')) {
    console.log(rel);
    continue;
  }
  const a64 = readFileSync(join(A, rel)).toString('base64');
  const b64 = readFileSync(join(B, rel)).toString('base64');
  const r = await page.evaluate(async ([x, y]) => {
    const load = (s) => new Promise((res) => { const i = new Image(); i.onload = () => res(i); i.src = 'data:image/png;base64,' + s; });
    const [ia, ib] = await Promise.all([load(x), load(y)]);
    if (ia.width !== ib.width || ia.height !== ib.height) return { size: `${ia.width}x${ia.height} → ${ib.width}x${ib.height}` };
    const c = document.getElementById('c'); c.width = ia.width; c.height = ia.height;
    const g = c.getContext('2d', { willReadFrequently: true });
    g.drawImage(ia, 0, 0); const da = g.getImageData(0, 0, c.width, c.height).data;
    g.clearRect(0, 0, c.width, c.height); g.drawImage(ib, 0, 0); const db = g.getImageData(0, 0, c.width, c.height).data;
    let n = 0, x0 = 1e9, y0 = 1e9, x1 = -1, y1 = -1;
    for (let p = 0; p < da.length; p += 4) {
      if (Math.abs(da[p] - db[p]) + Math.abs(da[p + 1] - db[p + 1]) + Math.abs(da[p + 2] - db[p + 2]) > 90) {
        n++; const px = (p / 4) % c.width, py = Math.floor(p / 4 / c.width);
        if (px < x0) x0 = px; if (px > x1) x1 = px; if (py < y0) y0 = py; if (py > y1) y1 = py;
      }
    }
    return { n, bbox: [x0, y0, x1, y1] };
  }, [a64, b64]);
  console.log(rel.padEnd(34), JSON.stringify(r));
}
await browser.close();
