// SPDX-License-Identifier: AGPL-3.0-or-later
//
// ひらいたメニュー(窓ではない、小さな吊り下げ)を、外のクリックと Esc で
// 閉じる。NavMenu が自分で持っていた二つの閉じかたを、ほかのメニューも
// 同じ形で使えるように、一か所に出したもの。
//
//   <div class="menu-wrap" {@attach dismissable(() => open, () => (open = false))}>
//     <button …>   ← 引き金
//     {#if open}<div role="menu">…</div>{/if}
//   </div>
//
// 付ける先は「引き金と中身の両方を含む」要素。引き金が外にあるとき
// (中身だけを包めるとき)は also に引き金を返す。引き金のクリックは
// 内側として数える ── 数えないと、開いたそのクリックで閉じてしまう。
// (開く→この付けものが走る、までの間に、同じクリックがまだ window へ
// 上っていく途中にある。)
//
// 外か内かは composedPath() で見る。中の項目を押して DOM から外れた
// 要素も、押した時点の道筋には居る。

import type { Attachment } from 'svelte/attachments';
import { onEscape } from '#lib/ux/escape.js';

export function dismissable(
  isOpen: () => boolean,
  close: () => void,
  also?: () => Element | null
): Attachment<HTMLElement> {
  return (root) => {
    if (!isOpen()) return;

    const offEscape = onEscape(close);
    const onClick = (e: MouseEvent) => {
      const path = e.composedPath();
      if (path.includes(root)) return;
      const extra = also?.();
      if (extra && path.includes(extra)) return;
      close();
    };
    window.addEventListener('click', onClick);

    return () => {
      window.removeEventListener('click', onClick);
      offEscape();
    };
  };
}
