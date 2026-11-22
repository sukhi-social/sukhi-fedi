// SPDX-License-Identifier: AGPL-3.0-or-later
// 通知のしるし(ベルの横の数・かたち)と、live。数え方・層の分け方は server/notify.ts。
//
//   GET  /notifications/unseen   しるしを、置き場ごと返す。頁と頁の境で、public/js/app.js が取りにくる
//   POST /notifications/seen     「ここまで見た」を、gateway の印に置く。通知の頁が開いたときに、頁が呼ぶ
//   GET  /notifications/stream   direct の通知が届いた、という呼び鈴(SSE)。中身は流さない
//
// 頁を描く GET(/notifications)は、何も書き換えない ── ナビのリンクは先読み(up-preload)されるので、
// 開く前に「見た」になってしまう。見たことにするのは、頁が本当に開いて、ブラウザが POST したときだけ。
//
// 呼び鈴の形(荷物ではない・繋ぎ直し・心拍)は server/sse.ts。token はブラウザには無いので、
// この郵便局が gateway の流れを読んで、direct のぶんだけを渡す。数は /notifications/unseen に訊き直す。

import { gw } from '../gateway.ts';
import { html } from '../html.ts';
import { empty, ok, route, Unauthorized } from '../http.ts';
import { frames, markSeen, tierOf, unseen } from '../notify.ts';
import { bell, later } from '../sse.ts';
import { notifSlots } from '../views/notify.ts';
import { quiet } from './shared.ts';

route(
  'GET',
  '/notifications/unseen',
  quiet(async (ctx) => {
    const count = await unseen(ctx);
    return ok(html`${notifSlots(ctx, 'top', count)}${notifSlots(ctx, 'bottom', count)}`);
  })
);

route(
  'POST',
  '/notifications/seen',
  quiet(async (ctx) => {
    await markSeen(ctx);
    return empty();
  })
);

route('GET', '/notifications/stream', async (ctx) => {
  if (!ctx.session?.token) return empty(401);

  const upstream = new AbortController();
  let res: Response;
  try {
    res = await gw(ctx, 'GET', '/api/v1/streaming/user/notification', { accept: 'text/event-stream', signal: upstream.signal });
  } catch (e) {
    // 入りなおしが要る人には、401(EventSource は、ここで繋ぎ直すのをやめる)。
    if (e instanceof Unauthorized) return empty(401);
    // gateway に届かない・流れの口が無い。
    return later();
  }
  const body = res.body;

  return bell(async (ring, gone) => {
    // ブラウザが去ったら、gateway の流れも閉じる。
    const stop = () => upstream.abort();
    if (gone.aborted) stop();
    else gone.addEventListener('abort', stop, { once: true });
    try {
      if (!body) return;
      for await (const f of frames(body)) {
        if (f.event !== 'notification') continue;
        try {
          // direct のぶんだけ。ambient は、頁と頁の境で数えなおすので、流れてきても渡さない。
          if (tierOf(JSON.parse(f.data).type) === 'direct') ring('direct');
        } catch {
          // 形がちがうフレームは、読めなかったことにする。
        }
      }
    } finally {
      stop();
    }
  });
});
