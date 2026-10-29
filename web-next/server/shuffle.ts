// 同じ「うつろい」のことばで呼ばれる投稿は、画面の上では、順序が分からない。
// (「今日の昼下がり」が三つ並んでいれば、どれが先かは、言えない。)
// だから、その中だけで、並べなおす。同じ人の続けざまの投稿が、ひとかたまりにならないように。
//
//   ・ことばの切れ目(=時間のことばが変わるところ)は、またがない。古いものが先に来たりはしない。
//   ・並べ方は、札(seed)と投稿の id だけで決まる。読み込みなおしても、同じ順。
//   ・同じ人が続かないように、できるかぎり。ほかに選べる人が居ないときは、そのまま続ける。

import type { Locale } from './i18n.ts';
import { timeWords } from './time.ts';
import type { Status } from './types.ts';

// 文字列から、ゆるい 32bit の数(FNV-1a)。乱数ではなく、「いつも同じ」のため。
function hash(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

const authorOf = (s: Status) => (s.reblog ?? s).account.id;

function spread(run: Status[], seed: string): Status[] {
  if (run.length < 3) return run; // ふたつなら、並べなおしても、人の入れ替えにしかならない
  const left = [...run].sort((a, b) => hash(`${seed}:${a.id}`) - hash(`${seed}:${b.id}`));
  const out: Status[] = [];
  while (left.length > 0) {
    const prev = out.length > 0 ? authorOf(out[out.length - 1]) : null;
    let i = left.findIndex((s) => authorOf(s) !== prev);
    if (i < 0) i = 0;
    out.push(left.splice(i, 1)[0]);
  }
  return out;
}

export function spreadWithinMoments(items: Status[], locale: Locale, seed: string, now: Date = new Date()): Status[] {
  const out: Status[] = [];
  let run: Status[] = [];
  let key: string | null = null;
  const flush = () => {
    out.push(...spread(run, seed));
    run = [];
  };
  for (const s of items) {
    const k = timeWords(s.created_at, locale, now);
    if (k !== key) flush();
    key = k;
    run.push(s);
  }
  flush();
  return out;
}
