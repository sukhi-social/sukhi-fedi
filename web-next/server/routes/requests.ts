// SPDX-License-Identifier: AGPL-3.0-or-later
// フォロー申請(鍵のアカウントに来る)。通知の行のボタンと、この一覧は、同じ答えの口を通る。
//
//   GET  /requests                    いま待っている申請の一覧(通知を消した人も、ここで見つかる)
//   POST /requests/:accountId/:verb   accept / decline。gateway の authorize / reject に写すだけ。

import { html } from '../html.ts';
import { gw, gwJson, GatewayError } from '../gateway.ts';
import { route, ok, redirect } from '../http.ts';
import type { Account } from '../types.ts';
import { layout } from '../views/layout.ts';
import { avatar } from '../views/parts.ts';
import { nameHtml, nameOf, requestButtons } from '../views/account.ts';
import { backOr, failText, needMe } from './shared.ts';

route('GET', '/requests', async (ctx) => {
  const t = ctx.t;
  const me = await needMe(ctx);
  const items = await gwJson<Account[]>(ctx, 'GET', '/api/v1/follow_requests').catch(() => null);

  const body = html`<header class="timeline page-head">
      <h1>${t('requests.title')}</h1>
    </header>
    ${items === null ? html`<p class="error">${t('common.readFailed')}</p>` : ''}
    ${items && items.length === 0 ? html`<p class="prose-small">${t('requests.empty')}</p>` : ''}
    ${items && items.length
      ? html`<section class="account-list">${items.map(
          (a) => html`<article class="account-row" id="rq-${a.id}">
            <a class="account-row-link" href="/@${a.acct}">
              ${avatar(a.avatar, nameOf(a))}
              <span class="stack-tight">
                <span class="display-name">${nameHtml(a)}</span>
                <span class="muted">@${a.acct}</span>
              </span>
            </a>
            ${requestButtons(ctx, a.id)}
          </article>`
        )}</section>`
      : ''}`;
  return ok(layout(ctx, { title: t('requests.title'), me, body }));
});

route('POST', '/requests/:id/:verb', async (ctx) => {
  const t = ctx.t;
  await needMe(ctx);
  const verb = ctx.params.verb === 'accept' ? 'authorize' : ctx.params.verb === 'decline' ? 'reject' : null;
  if (!verb) return redirect('/requests');
  const f = await ctx.form();
  const nf = String(f.get('nf') ?? '').replace(/[^\w-]/g, '');
  const accountId = ctx.params.id;

  try {
    await gw(ctx, 'POST', `/api/v1/follow_requests/${encodeURIComponent(accountId)}/${verb}`, { json: {} });
  } catch (e) {
    if (!(e instanceof GatewayError)) throw e;
    ctx.flash('error', failText(ctx, e));
    return backOr(ctx, null);
  }
  // 答えた通知は片づける。失敗しても、答えは済んでいる。
  if (nf) await gw(ctx, 'POST', `/api/v1/notifications/${encodeURIComponent(nf)}/dismiss`, { json: {} }).catch(() => undefined);

  const said = html`<p class="prose-small">${t(verb === 'authorize' ? 'requests.accepted' : 'requests.declined')}</p>`;
  return backOr(ctx, nf ? html`<article class="notif notif-answered" id="nf-${nf}">${said}</article>` : html`<article class="account-row" id="rq-${accountId}">${said}</article>`);
});
