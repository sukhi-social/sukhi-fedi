// SPDX-License-Identifier: AGPL-3.0-or-later
// フォロー申請(鍵のアカウントに来る)。通知の行のボタンと、この一覧は、同じ答えの口を通る。
//
//   GET  /requests                    いま待っている申請の一覧(通知を消した人も、ここで見つかる)と、招待リンク
//   POST /requests/:accountId/:verb   accept / decline。gateway の authorize / reject に写すだけ。
//   POST /requests/invites            招待リンクを一つ作る(鍵のアカウントが、待たずに迎えたい人へ渡す)
//   POST /requests/invites/:code/delete  その招待リンクを取り消す

import { config } from '../config.ts';
import { html, type SafeHtml } from '../html.ts';
import { gw, gwJson, GatewayError } from '../gateway.ts';
import { route, ok, redirect, type Ctx } from '../http.ts';
import type { Account } from '../types.ts';
import { layout } from '../views/layout.ts';
import { avatar } from '../views/parts.ts';
import { nameHtml, nameOf, requestButtons } from '../views/account.ts';
import { backOr, failText, needMe } from './shared.ts';

// ── 招待リンク ──────────────────────────────────────────────────
// gateway は code だけを返す。渡すリンクは、この家の origin に、gateway が受ける道(/users/:name/invites/:code)を足したもの。
type FollowInvite = { code: string };

const inviteLink = (me: Account, code: string) => `${config.publicOrigin}/users/${encodeURIComponent(me.username)}/invites/${encodeURIComponent(code)}`;

// 作る・取り消すの答えは、この区画ごと。一覧は gateway から引きなおす(手元でつぎはぎしない)。
async function invitesSection(ctx: Ctx, me: Account, error?: string): Promise<SafeHtml> {
  const t = ctx.t;
  const items = await gwJson<FollowInvite[]>(ctx, 'GET', '/api/v1/follow_invites').catch(() => null);
  return html`<section class="stack-tight" id="invites">
    <h2 class="text-base">${t('invites.heading')}</h2>
    <p class="prose-small muted">${t('invites.hint')}</p>
    ${error ? html`<p class="error">${error}</p>` : ''}
    ${items === null ? html`<p class="error">${t('common.readFailed')}</p>` : ''}
    <form method="post" action="/requests/invites" in-place up-target="#invites">
      <button type="submit" class="chip">${t('invites.create')}</button>
    </form>
    ${items && items.length === 0 ? html`<p class="prose-small muted">${t('invites.empty')}</p>` : ''}
    ${items?.map((i) => {
      const link = inviteLink(me, i.code);
      return html`<div class="invite-row" id="inv-${i.code}" x-data="{ copied: false }">
        <code class="invite-link">${link}</code>
        <div class="request-actions">
          <button type="button" class="chip" @click="navigator.clipboard.writeText(${JSON.stringify(link)}).then(() => (copied = true))" x-text="copied ? ${JSON.stringify(t('invites.copied'))} : ${JSON.stringify(t('invites.copy'))}">${t('invites.copy')}</button>
          <form method="post" action="/requests/invites/${encodeURIComponent(i.code)}/delete" in-place up-target="#invites">
            <button type="submit" class="chip">${t('invites.revoke')}</button>
          </form>
        </div>
      </div>`;
    })}
  </section>`;
}

route('POST', '/requests/invites', async (ctx) => {
  const me = await needMe(ctx);
  let error: string | undefined;
  try {
    await gw(ctx, 'POST', '/api/v1/follow_invites', { json: {} });
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    error = failText(ctx, e);
  }
  return backOr(ctx, await invitesSection(ctx, me, error));
});

route('POST', '/requests/invites/:code/delete', async (ctx) => {
  const me = await needMe(ctx);
  let error: string | undefined;
  try {
    await gw(ctx, 'DELETE', `/api/v1/follow_invites/${encodeURIComponent(ctx.params.code)}`);
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    error = failText(ctx, e);
  }
  return backOr(ctx, await invitesSection(ctx, me, error));
});

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
      : ''}
    <div class="timeline">${await invitesSection(ctx, me)}</div>`;
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
