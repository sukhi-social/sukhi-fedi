// 「いま混み合っています」を、画面ぜんたいで一つだけ持つ置き場。
//
// サーバは混んだとき、429(レート制限)か 503(DB の順番待ちが切れた、
// 裏の node が間に合わない)を、`retry-after` つきで返す。これまでは
// 画面ごとに 429 を拾うか、素の JSON がそのまま出ていた。`api.ts` の
// `req` が全部の呼び出しの入口なので、ここで一度だけ受けて、時刻を置く。
// 見せるのは BusyBanner。成功が一度でも返れば、混雑は終わったと見て消す。

export { isBusyStatus, retrySeconds } from './busy.js';

export const busy = $state<{ until: number }>({ until: 0 });

export function markBusy(seconds: number, now: number = Date.now()) {
  busy.until = Math.max(busy.until, now + seconds * 1000);
}

export function clearBusy() {
  if (busy.until !== 0) busy.until = 0;
}
