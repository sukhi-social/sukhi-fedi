// 「いま混み合っています」を、画面ぜんたいで一つだけ持つ置き場。
//
// サーバは混んだとき、429(レート制限)か 503(DB の順番待ちが切れた、
// 裏の node が間に合わない)を、`retry-after` つきで返す。これまでは
// 画面ごとに 429 を拾うか、素の JSON がそのまま出ていた。`api.ts` の
// `req` が全部の呼び出しの入口なので、ここで一度だけ受けて、時刻を置く。
// 見せるのは BusyBanner。成功が一度でも返れば、混雑は終わったと見て消す。

import { slotFor } from './busy.js';

export { isBusyStatus, retrySeconds, reasonText } from './busy.js';

export const busy = $state<{ until: number; reason: string | null }>({ until: 0, reason: null });

export function markBusy(seconds: number, reason: string | null = null, now: number = Date.now()) {
  busy.until = Math.max(busy.until, now + seconds * 1000);
  busy.reason = reason;
  slowDown(seconds, now);
}

// 429 / 503 を受けたら、`retry-after` が過ぎるまで、こちらからは送らない。
// 送れば、そのぶん 429 がまた返り、返るたびにサーバ側の「おいた」の数に
// 入る。ゆっくり(間隔をあける)だけでは、制限の窓の中にいるあいだ 1 秒に
// 1 回ずつ叩き続けて、長めの制限に入ってしまう。`busy.until` は表示用、
// こちらは送るかどうかの判断。成功が返れば(clearBusy)解く。
export function isHeld(now: number = Date.now()): boolean {
  return now < busy.until;
}

export function clearBusy() {
  if (busy.until !== 0) busy.until = 0;
  busy.reason = null;
}

// ── ゆっくり ──
// サーバが `x-slow-down: 秒` を付けてきたら(枠の 8 割を超えたしるし)、
// その秒数のあいだ、リクエストの開始を間隔をあけて並べる。429 が返った
// ときも同じ。画面には出さない ── 静かに、ゆっくりにするだけ。
let slowUntil = 0;
let nextFree = 0;

export function slowDown(seconds: number, now: number = Date.now()) {
  slowUntil = Math.max(slowUntil, now + seconds * 1000);
}

export async function waitTurn(): Promise<void> {
  const slot = slotFor(Date.now(), slowUntil, nextFree);
  nextFree = slot.nextFree;
  if (slot.wait > 0) await new Promise((r) => setTimeout(r, slot.wait));
}
