// SPDX-License-Identifier: AGPL-3.0-or-later
// ブロック・ミュートしている人の一覧と、解く場所。かけるのはプロフィールの「…」(routes/write.ts の
// POST /accounts/:id/:verb)で、解くのも同じ口を通る ── 一覧からは、解いた行を空にして返す。

import { html } from '../html.ts';
import { gwJson } from '../gateway.ts';
import { ok, route } from '../http.ts';
import type { Account } from '../types.ts';
import { layout } from '../views/layout.ts';
import { avatar } from '../views/parts.ts';
import { nameHtml, nameOf } from '../views/account.ts';
import { needMe } from './shared.ts';

route('GET', '/settings/people', async (ctx) => {
  const t = ctx.t;
  const me = await needMe(ctx);
  const [blocks, mutes] = await Promise.all([
    gwJson<Account[]>(ctx, 'GET', '/api/v1/blocks').catch(() => null),
    gwJson<Account[]>(ctx, 'GET', '/api/v1/mutes').catch(() => null)
  ]);

  const section = (title: string, kind: 'bl' | 'mu', verb: 'unblock' | 'unmute', items: Account[] | null) => html`<section class="stack-tight">
    <h2 class="text-base">${title}</h2>
    ${items === null ? html`<p class="error">${t('common.readFailed')}</p>` : ''}
    ${items && items.length === 0 ? html`<p class="prose-small">${t('settings.noneHere')}</p>` : ''}
    ${items && items.length
      ? html`<div class="account-list">${items.map(
          (a) => html`<article class="account-row" id="${kind}-${a.id}">
            <a class="account-row-link" href="/@${a.acct}">
              ${avatar(a.avatar, nameOf(a))}
              <span class="stack-tight">
                <span class="display-name">${nameHtml(a)}</span>
                <span class="muted">@${a.acct}</span>
              </span>
            </a>
            <form method="post" action="/accounts/${a.id}/${verb}" in-place>
              <input type="hidden" name="row" value="${kind}-${a.id}" />
              <button type="submit" class="chip">${t('settings.release')}</button>
            </form>
          </article>`
        )}</div>`
      : ''}
  </section>`;

  const body = html`<header class="timeline page-head"><h1>${t('settings.blockMute')}</h1></header>
    <div class="timeline stack">
      <div class="settings-form">
        ${section(t('settings.blocking'), 'bl', 'unblock', blocks)}
        ${section(t('settings.muting'), 'mu', 'unmute', mutes)}
        <p class="prose-small"><a class="chip" href="/settings">${t('security.backToSettings')}</a></p>
      </div>
    </div>`;
  return ok(layout(ctx, { title: t('settings.blockMute'), me, body }));
});
