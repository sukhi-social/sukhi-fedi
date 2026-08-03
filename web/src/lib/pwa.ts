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

export function registerServiceWorker() {
  if (!browser) return;
  if (!('serviceWorker' in navigator)) return;

  // dev では登録しない。HMR と喧嘩するうえ、古い shell を掴んで
  // 「直したのに直らない」になる。
  if (import.meta.env.DEV) return;

  navigator.serviceWorker.register('/service-worker.js', { scope: '/' }).catch(() => {
    // 登録できなくてもアプリは動く(installable でなくなるだけ)。黙って諦める。
  });
}
