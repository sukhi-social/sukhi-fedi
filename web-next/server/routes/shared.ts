// SPDX-License-Identifier: AGPL-3.0-or-later
// 道をまたいで使う、小さな助け。

import { html, type SafeHtml } from '../html.ts';
import { gwJson, GatewayError } from '../gateway.ts';
import { redirect, ok, Unauthorized, type Ctx, type Reply } from '../http.ts';
import { saveSession } from '../session.ts';
import type { Account, Status } from '../types.ts';
import { statusCard, theEnd } from '../views/status.ts';

// 入っている人。入っていなければ Unauthorized(→ /login へ)。
export async function needMe(ctx: Ctx): Promise<Account> {
  const me = await ctx.me();
  if (!me) throw new Unauthorized();
  return me;
}

// 公開の頁のための「入っていれば、入っている人」。トークンが古くて戻せなかったら、静かに「入っていない人」。
export async function maybeMe(ctx: Ctx): Promise<Account | null> {
  try {
    return await ctx.me();
  } catch (e) {
    if (!(e instanceof Unauthorized)) throw e;
    const s = ctx.session;
    if (s) {
      s.token = undefined;
      s.me = undefined;
      saveSession(s);
    }
    return null;
  }
}

// 返信先の acct を、id から引く。同じ人を何度も引かないよう、手元にしばらく覚えておく。
const acctCache = new Map<string, { acct: string; at: number }>();
const ACCT_TTL = 10 * 60_000;
const ACCT_MAX = 500;

export async function replyAcctsFor(ctx: Ctx, statuses: Status[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const need = new Set<string>();
  const now = Date.now();
  for (const s of statuses) {
    const inner = s.reblog ?? s;
    const id = inner.in_reply_to_account_id;
    if (!inner.in_reply_to_id || !id) continue;
    const hit = acctCache.get(id);
    if (hit && now - hit.at < ACCT_TTL) out.set(id, hit.acct);
    else need.add(id);
  }
  // 一頁に何人も並んでも、引くのは多くて十人まで。残りは、名前なしの「返信」。
  await Promise.all(
    [...need].slice(0, 10).map(async (id) => {
      try {
        const a = await gwJson<Account>(ctx, 'GET', `/api/v1/accounts/${encodeURIComponent(id)}`, { auth: false });
        if (acctCache.size >= ACCT_MAX) acctCache.delete(acctCache.keys().next().value!);
        acctCache.set(id, { acct: a.acct, at: now });
        out.set(id, a.acct);
      } catch {
        // 引けなかった人は、そのまま。
      }
    })
  );
  return out;
}

// 投稿の列。終わりの印か、「もっと読む」のどちらかが、かならず末尾に付く。
//   moreHref を渡すと、Unpoly が「あとに足す」道(#items:after と #more の差し替え)になる。
export async function statusList(
  ctx: Ctx,
  items: Status[],
  o: { me: Account | null; idPrefix: string; moreHref: string | null; full?: boolean }
): Promise<SafeHtml> {
  const replyAccts = await replyAcctsFor(ctx, items);
  const more = o.moreHref
    ? html`<a class="load-more" href="${o.moreHref}" up-target="#${o.idPrefix}-items:after, #${o.idPrefix}-more" up-history="false" up-scroll="false" up-revalidate="false">${ctx.t('common.loadMore')}</a>`
    : items.length > 0
      ? theEnd(ctx)
      : '';
  return html`<div id="${o.idPrefix}-items">${items.map((s) => statusCard(ctx, s, { me: o.me, replyAccts, full: o.full }))}</div>
    <div id="${o.idPrefix}-more">${more}</div>`;
}

// 押した・消した、のあと。Unpoly なら押したところだけを返し、そうでなければ元の頁へ戻す。
export function backOr(ctx: Ctx, fragment: SafeHtml | null): Reply {
  if (ctx.isUp && fragment) return ok(fragment);
  const ref = ctx.req.headers.referer;
  if (ref) {
    try {
      const u = new URL(ref);
      if (u.host === ctx.req.headers.host) return redirect(u.pathname + u.search);
    } catch {
      // 戻り先が読めなければ、ホームへ。
    }
  }
  return redirect('/');
}

// gateway のエラーを、やさしいひとことに。
export function failText(ctx: Ctx, e: unknown): string {
  if (e instanceof GatewayError) {
    if (e.status === 429) return ctx.t('compose.err.rateLimited');
    if (e.status === 413) return ctx.t('compose.err.tooLarge');
    if (e.status === 422) return ctx.t('compose.err.invalid');
    if (e.status === 502 || e.status === 503) return ctx.t('compose.err.busy');
  }
  if (e instanceof TypeError) return ctx.t('compose.err.network');
  return ctx.t('common.deliverFailedRetry');
}
