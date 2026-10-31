// SPDX-License-Identifier: AGPL-3.0-or-later
// 静的ファイルの置き場(url → ディスク)と、頁から読む版つきの URL。
//
// Cloudflare は、origin の Cache-Control を待たず、静的ファイルに max-age=14400 を足す。
// URL が同じままだと、デプロイのあとも、ブラウザは最長 4 時間、古い CSS・JS を使い続ける。
// 頁が読むときは assetUrl() を通す。中身が変わると ?v= が変わるので、新しい版がすぐ届く。

import { createHash } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { join, normalize, sep } from 'node:path';
import { config } from './config.ts';

// url の前置き → ディスクの場所。長い前置きが先。
const MOUNTS: [string, string, boolean][] = [
  ['/assets/vendor/unpoly/', `${config.nodeModules}unpoly/`, true],
  ['/assets/vendor/alpine/', `${config.nodeModules}alpinejs/dist/`, true],
  ['/assets/fonts/', `${config.nodeModules}@fontsource/`, true],
  ['/twemoji/svg/', `${config.nodeModules}@twemoji/svg/`, true],
  // ロゴなど、image を焼きなおさずに差し替えたいもの(SITE_LOGO=/brand/<ファイル名>)。volume の中。
  ['/brand/', `${config.dataDir}brand/`, false],
  ['/assets/', config.publicDir, false]
];

export type Located = { full: string; immutable: boolean };

// base の外へ出る相対パスは、見つからなかったことにする。
export function locateIn(base: string, rel: string, immutable: boolean): Located | null {
  const full = normalize(join(base, decodeURIComponent(rel)));
  if (full !== base.replace(/\/$/, '') && !full.startsWith(base.endsWith(sep) ? base : base + sep)) return null;
  return { full, immutable };
}

export function locate(pathname: string): Located | null {
  for (const [prefix, dir, immutable] of MOUNTS) {
    if (pathname.startsWith(prefix)) return locateIn(dir, pathname.slice(prefix.length), immutable);
  }
  return null;
}

// 中身の指紋。ファイルの大きさと更新時刻が同じあいだは、読みなおさない。
const seen = new Map<string, { mtimeMs: number; size: number; v: string }>();

export function assetUrl(pathname: string): string {
  const at = locate(pathname);
  if (!at) return pathname;
  try {
    const st = statSync(at.full);
    if (!st.isFile()) return pathname;
    const known = seen.get(at.full);
    if (known && known.mtimeMs === st.mtimeMs && known.size === st.size) return `${pathname}?v=${known.v}`;
    const v = createHash('sha256').update(readFileSync(at.full)).digest('hex').slice(0, 10);
    seen.set(at.full, { mtimeMs: st.mtimeMs, size: st.size, v });
    return `${pathname}?v=${v}`;
  } catch {
    return pathname;
  }
}
