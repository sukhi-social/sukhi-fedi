// 絵文字の付け外し ── 手元でどう変わるか、だけ。
//
// 押した瞬間に手元を書き換えて、返事は後から待つ(楽観)。だからこの計算は
// 二箇所(投稿カードと、会話の一通)から呼ばれる。同じ規則が二つあると、
// いつか片方だけ直る ── なので、ここ一つにする。
//
// 通信も状態も持たない。呼ぶ側が「次はこれ」を受け取って、失敗したら
// 前のものに戻す。

import type { Reaction } from './api';

// Clips のピンは、専用の列ではなくこの絵文字のリアクション(自分の投稿への
// 自分のリアクション)そのもの。付ける側(DmMessage)と絞り込む側
// (clips/+page.svelte)の両方が同じ文字列を見るので、ここ一箇所に置く。
export const PIN_EMOJI = '📌';

/** 押したら付くのか、外れるのか。react / unreact のどちらを呼ぶかが決まる。 */
export function willAdd(list: Reaction[], emoji: string): boolean {
  const found = list.find((r) => r.name === emoji);
  return !found || !found.me;
}

/** 押したあとの並び。自分のぶんが 0 になった絵文字は、消える。 */
export function toggled(list: Reaction[], emoji: string): Reaction[] {
  const idx = list.findIndex((r) => r.name === emoji);

  // まだ誰も付けていない絵文字 ── 自分が最初。
  if (idx < 0) return [...list, { name: emoji, count: 1, me: true }];

  const cur = list[idx];

  // 自分が付けていたのを外す。ほかに誰も居なければ、その絵文字ごと消える。
  if (cur.me) {
    const next = { ...cur, me: false, count: cur.count - 1 };
    return next.count <= 0
      ? list.filter((_, i) => i !== idx)
      : list.map((x, i) => (i === idx ? next : x));
  }

  // ほかの人が付けているところに、自分も乗る。
  return list.map((x, i) => (i === idx ? { ...x, me: true, count: x.count + 1 } : x));
}
