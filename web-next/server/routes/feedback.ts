// SPDX-License-Identifier: AGPL-3.0-or-later
// ご意見。入っていなくても送れる(gateway の口が、そう開いている)。
// 届くのは、本文と、ことば(ja / ko / en)と、「web-next」という画面の名前だけ。
// アカウント名も、端末の名前も、この頁からは足さない(入っていれば、gateway が自分の id を足す)。
// 回数の上限は gateway が持つ(15 分に 5 回)── ここでは数えない。

import { html } from '../html.ts';
import { gwJson, GatewayError } from '../gateway.ts';
import { ok, route, type Ctx } from '../http.ts';
import { layout } from '../views/layout.ts';
import { maybeMe } from './shared.ts';

const MAX = 2000;

async function page(ctx: Ctx, o: { text?: string; error?: string; sent?: boolean; status?: number } = {}) {
  const t = ctx.t;
  const me = await maybeMe(ctx);
  const body = html`<header class="timeline page-head"><h1>${t('feedback.title')}</h1></header>
    <div class="timeline stack">
      ${o.sent
        ? html`<p class="notice" role="status">${t('feedback.thanks')}</p>
            <p class="prose-small"><a class="chip" href="/">${t('feedback.close')}</a></p>`
        : html`<form class="settings-form" method="post" action="/feedback">
            <p class="muted text-sm">${t('feedback.hint')}</p>
            ${o.error ? html`<p class="error" role="alert">${o.error}</p>` : ''}
            <label class="stack-tight">
              <span class="visually-hidden">${t('feedback.label')}</span>
              <textarea name="body" rows="8" required autofocus>${o.text ?? ''}</textarea>
            </label>
            <div class="row"><button type="submit" class="btn">${t('feedback.send')}</button></div>
          </form>`}
    </div>`;
  return ok(layout(ctx, { title: t('feedback.title'), me, entrance: !me, legal: !me, body }), o.status ?? 200);
}

route('GET', '/feedback', (ctx) => page(ctx));

route('POST', '/feedback', async (ctx) => {
  const t = ctx.t;
  const text = String((await ctx.form()).get('body') ?? '');
  const body = text.trim();
  if (!body) return page(ctx, { text, error: t('feedback.empty'), status: 422 });
  if ([...body].length > MAX) return page(ctx, { text, error: t('feedback.tooLong'), status: 422 });
  try {
    await gwJson(ctx, 'POST', '/api/v1/feedback', { auth: 'optional', json: { body, screen: 'web-next', lang: ctx.locale } });
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    const limited = e instanceof GatewayError && e.status === 429;
    return page(ctx, { text, error: limited ? t('feedback.rateLimited') : t('feedback.failed'), status: limited ? 429 : 502 });
  }
  return page(ctx, { sent: true });
});
