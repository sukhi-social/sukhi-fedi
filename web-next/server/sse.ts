// SPDX-License-Identifier: AGPL-3.0-or-later
// 呼び鈴(SSE)の道の形。通知(routes/notify.ts)も、ふたりの部屋(routes/rooms.ts)も、ここを通る。
//
// 呼び鈴は、荷物ではない。鳴ったら「見にきて」と言うだけで、中身は流さない。
// 切れているあいだに来たぶんは、流れてこない ── 荷物にすると、そこが穴になる。
// ブラウザは、繋ぎ直したとき・鳴ったときに、API に訊き直す。
//
// ・EventSource は、200 でないと繋ぎ直さない。だから gateway に届かないときも 200 で、
//   「あとでまた」(retry: LATER_MS)とだけ言って閉じる。入りなおしが要る人にだけ、401(ここでは返さず、道が返す)。
// ・こちらからの心拍(BEAT_MS)で、ブラウザと郵便局のあいだの道を温めておく。gateway の心拍とは別。

import type { Reply } from './http.ts';

// ブラウザが切れたあとに繋ぎ直すまでの間(EventSource の retry)。
const RETRY_MS = 5_000;
// gateway に届かないときは、長めに。
const LATER_MS = 60_000;
const BEAT_MS = 25_000;

const sse = (stream: NonNullable<Reply['stream']>): Reply => ({
  status: 200,
  // x-accel-buffering: 手前の nginx に、溜めずに流してもらう。
  headers: { 'content-type': 'text/event-stream; charset=utf-8', 'x-accel-buffering': 'no' },
  body: '',
  stream
});

/** 流れの口に届かないとき。「あとでまた」と言って閉じる。 */
export const later = (): Reply => sse(async (write) => write(`retry: ${LATER_MS}\n\n`));

/**
 * 呼び鈴を、ブラウザへ流す。`listen` は、向こうの流れを読んで、鳴らすとき `ring(イベント名)` を呼ぶ。
 * `gone` は、ブラウザが去った合図 ── そのとき向こうの流れも閉じるのは、`listen` の仕事。
 * `listen` が終われば(向こうが切れた)、こちらも閉じる。ブラウザが繋ぎ直す。
 */
export function bell(listen: (ring: (event: string) => void, gone: AbortSignal) => Promise<void>): Reply {
  return sse(async (write, gone) => {
    write(`retry: ${RETRY_MS}\n\n`);
    const beat = setInterval(() => write(':thump\n\n'), BEAT_MS);
    try {
      await listen((event) => write(`event: ${event}\ndata: 1\n\n`), gone);
    } catch {
      // 切れた(ブラウザが去った・向こうが切った)。ブラウザが繋ぎ直す ── そのとき訊き直す。
    } finally {
      clearInterval(beat);
    }
  });
}
