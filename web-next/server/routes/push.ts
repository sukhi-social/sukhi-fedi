// SPDX-License-Identifier: AGPL-3.0-or-later
// 知らせ(Web Push)の、購読の口。トークンはサーバにあるので、ブラウザは gateway を直接呼べない。
// ブラウザ(public/js/pwa.js)は、ここへ JSON を取りに来て、フォームを置いていく。
//
//   GET  /push/config       鍵・状態(押す前に、ぜんぶ確かめられるように)
//   POST /push/subscribe    購読を gateway に置く。alerts はここで作る(ブラウザは足せない)
//   POST /push/unsubscribe  この端末の購読だったときだけ、gateway から外す
//
// 鳴っていい種類は gateway が決める(server/push.ts)。起動時に許可を訊いたりしない ── 始めるのは、人の側。

import { GatewayError, gw, gwJson } from '../gateway.ts';
import { route, Unauthorized, type Ctx, type Reply } from '../http.ts';
import { alertsFor, hasPushScope, readPushConfig } from '../push.ts';

function json(body: unknown, status = 200): Reply {
  return {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
    body: JSON.stringify(body)
  };
}

// ふつうの頁と違って、入っていない人を /login へ送らない(fetch が追いかけてしまう)。401 を返す。
function guard(handler: (ctx: Ctx) => Promise<Reply>) {
  return async (ctx: Ctx): Promise<Reply> => {
    if (!ctx.session?.token) return json({ error: 'unauthorized' }, 401);
    try {
      return await handler(ctx);
    } catch (e) {
      if (e instanceof Unauthorized) return json({ error: 'unauthorized' }, 401);
      if (e instanceof GatewayError) return json({ error: e.message }, e.status >= 500 ? 502 : e.status);
      throw e;
    }
  };
}

async function instanceConfig(ctx: Ctx) {
  return readPushConfig(await gwJson(ctx, 'GET', '/api/v2/instance', { auth: false }));
}

// いまの購読(endpoint)。無ければ null(gateway は 404)。
async function currentEndpoint(ctx: Ctx): Promise<string | null> {
  try {
    const row = await gwJson<{ endpoint?: string }>(ctx, 'GET', '/api/v1/push/subscription');
    return row?.endpoint ?? null;
  } catch (e) {
    if (e instanceof GatewayError && e.status === 404) return null;
    throw e;
  }
}

route(
  'GET',
  '/push/config',
  guard(async (ctx) => {
    const config = await instanceConfig(ctx);
    return json({
      serverKey: config.serverKey,
      scopeOk: hasPushScope(ctx.session?.token?.scope),
      // 空の一覧では、鳴らす先が無い。出さないほうがいい。
      configured: !!config.serverKey && config.directTypes.length > 0,
      endpoint: config.serverKey ? await currentEndpoint(ctx) : null
    });
  })
);

route(
  'POST',
  '/push/subscribe',
  guard(async (ctx) => {
    const f = await ctx.form();
    const endpoint = String(f.get('endpoint') ?? '');
    const p256dh = String(f.get('p256dh') ?? '');
    const auth = String(f.get('auth') ?? '');
    if (!/^https:\/\//.test(endpoint) || !p256dh || !auth) return json({ error: 'invalid_subscription' }, 422);

    const { directTypes } = await instanceConfig(ctx);
    if (directTypes.length === 0) return json({ error: 'push_unavailable' }, 409);

    await gwJson(ctx, 'POST', '/api/v1/push/subscription', {
      json: { subscription: { endpoint, keys: { p256dh, auth } }, data: { alerts: alertsFor(directTypes) } }
    });
    return json({ ok: true });
  })
);

route(
  'POST',
  '/push/unsubscribe',
  guard(async (ctx) => {
    const endpoint = String((await ctx.form()).get('endpoint') ?? '');
    // gateway の購読は、アカウントに一つ。別の端末のものを、ここから外してしまわない。
    if (endpoint && endpoint === (await currentEndpoint(ctx))) await gw(ctx, 'DELETE', '/api/v1/push/subscription');
    return json({ ok: true });
  })
);
