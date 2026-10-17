// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 窓(モーダル)の「閉じかた」を、ひとつの形にそろえる。
//
//   Esc      … 一番上の窓がひとつ閉じる(escape.ts)
//   戻る     … 窓が閉じる。いまの画面ごと離れない
//
// 二つ目が Android で効く。システムの戻る(ジェスチャでも)は、Web では
// 「履歴をひとつ戻る」になる。窓が履歴を使っていないと、写真を拡大して
// 戻るを押しただけで、タイムラインごと離れてしまう。Android の
// Predictive back も「戻るのスタックに従う」ことを前提にしている。
// そこで窓を開いたとき、同じ URL のまま履歴にひとつ足し(SvelteKit の
// 浅い遷移)、戻るでそれが消えたら閉じる。
//
// 使いかた(窓を開くコンポーネントの script の中で):
//
//   useOverlay(() => lightbox !== null, () => (lightbox = null));
//   useOverlay(() => true, oncancel);   // 開いている間だけ在るコンポーネント
//
// 知っておくこと:
//   ・窓の中のリンクで別の画面へ行くと、足した履歴がひとつ後ろに残り、
//     そこへ戻ったとき戻るをもう一度押すことになる。窓の中から画面を
//     離れる使い方は、いまのところ無い。
//   ・SvelteKit 3 では pushState は非推奨で、goto の state + shallow が
//     いまの形。

import { untrack } from 'svelte';
import { goto } from '$app/navigation';
import { page } from '$app/state';
import { onEscape } from '#lib/ux/escape.js';

let seq = 0;

export function useOverlay(isOpen: () => boolean, close: () => void): void {
  const id = ++seq;
  // 履歴を足すと頼んだ
  let pushed = false;
  // page.state が、実際に自分の印になった
  let seen = false;

  $effect(() => {
    if (!isOpen()) return;
    return onEscape(close);
  });

  $effect(() => {
    const open = isOpen();
    untrack(() => {
      if (open && !pushed) {
        pushed = true;
        // shallow のとき reset は既定で false ── スクロールもフォーカスも動かさない。
        void goto(page.url.href, { state: { ux: id }, shallow: true });
      } else if (!open && pushed) {
        leave();
      }
    });
  });

  // 戻る(や遷移)で自分の印が消えたら、閉じる。
  $effect(() => {
    const mine = page.state.ux === id;
    untrack(() => {
      if (mine) {
        if (pushed) seen = true;
        else history.back(); // 頼んだ直後に閉じられた。残った印を片づける
      } else if (seen) {
        seen = false;
        pushed = false;
        close();
      }
    });
  });

  // こちらから閉じたときは、足した履歴も取り下げる(戻るを一回ぶん無駄に
  // させない)。もう戻るで消えていれば、何もしない。
  function leave() {
    pushed = false;
    if (seen && page.state.ux === id) {
      seen = false;
      history.back();
    }
  }

  $effect(() => () => untrack(leave));
}
