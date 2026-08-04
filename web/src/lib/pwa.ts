// service worker を登録するだけ。
//
// 中身は static/service-worker.js(手書き、依存なし)。ここは登録の一手だけを
// 持つ ── devAutoLogin() と同じで、layout から一度呼ばれる。
//
// 更新は既に導線がある(UpdateBanner + svelte.config.js の
// version.pollInterval)。だから、ここで registration.update() を叩いたり
// waiting を促したりは **しない**。二重に「更新」が起きると、どちらが本当か
// 分からなくなる。SW 側も skipWaiting() を呼ばない。

import { browser } from '$app/environment';
import { writable } from 'svelte/store';

/**
 * 新しい service worker が、代わる番を待っている。
 *
 * `$updated`(ページの版が変わった)とは別の合図。**worker だけが新しい**
 * ことがあって、そのとき `$updated` は動かない ── 静かに古いふるまいの
 * ままになる。通知の畳みかたを直した日がそれで、直っていない worker が
 * 鳴らし続けた。更新バナーは、こちらも見る。
 */
export const swWaiting = writable(false);

export function registerServiceWorker() {
  if (!browser) return;
  if (!('serviceWorker' in navigator)) return;

  // dev では登録しない。HMR と喧嘩するうえ、古い shell を掴んで
  // 「直したのに直らない」になる。
  if (import.meta.env.DEV) return;

  navigator.serviceWorker
    .register('/service-worker.js', { scope: '/' })
    .then((reg) => {
      // もう待っている(前の訪問で降りてきていた)。
      if (reg.waiting) swWaiting.set(true);

      // これから降りてくるぶん。installed になって、かつ既に誰かが動いて
      // いるなら、それは「入れ替わり待ち」── 初めての登録ではない。
      reg.addEventListener('updatefound', () => {
        const next = reg.installing;
        if (!next) return;
        next.addEventListener('statechange', () => {
          if (next.state === 'installed' && navigator.serviceWorker.controller) {
            swWaiting.set(true);
          }
        });
      });
    })
    .catch(() => {
      // 登録できなくてもアプリは動く(installable でなくなるだけ)。黙って諦める。
    });
}
