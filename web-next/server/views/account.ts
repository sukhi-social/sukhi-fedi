// SPDX-License-Identifier: AGPL-3.0-or-later
// 人の一行と、フォローのボタン。AccountRow.svelte / FollowButton.svelte の置き換え。
// フォロワーの数は、どこにも出さない。

import { html, raw, type SafeHtml } from '../html.ts';
import type { Ctx } from '../http.ts';
import type { Account, Relationship } from '../types.ts';
import { renderEmojis } from '../emoji.ts';
import { phrase } from '../phrase.ts';
import { avatar } from './parts.ts';

// 名前が無い人は、ハンドルで呼ぶ。リモートの人は user@host まで ── user だけだと、どこの誰か分からない。
export const nameOf = (a: Account) => a.display_name || a.acct || a.username;
export const nameHtml = (a: Account) => raw(renderEmojis(phrase(nameOf(a)), a.emojis));

// 押したところだけを差し替える。
export function followButton(ctx: Ctx, accountId: string, rel: Relationship): SafeHtml {
  const state = rel.following ? 'following' : rel.requested ? 'requested' : 'none';
  const label = state === 'following' ? ctx.t('follow.following') : state === 'requested' ? ctx.t('follow.requested') : ctx.t('follow.follow');
  const verb = rel.following || rel.requested ? 'unfollow' : 'follow';
  return html`<form id="follow-${accountId}" method="post" action="/accounts/${accountId}/${verb}" in-place>
    <button type="submit" class="follow-btn" data-state="${state}">${label}</button>
  </form>`;
}

// プロフィールの右上の一塊: フォローと、「…」(ミュート・ブロック)。ミュート・ブロックのあとは
// フォローの状態も変わるので、この一塊ごと差し替える(`#pf-actions`)。
export function profileActions(ctx: Ctx, accountId: string, rel: Relationship): SafeHtml {
  const t = ctx.t;
  const act = (verb: string, label: string, opts: { danger?: boolean; confirm?: string } = {}) => html`<form method="post" action="/accounts/${accountId}/${verb}" in-place up-target="#pf-actions" ${opts.confirm ? html`up-confirm="${opts.confirm}"` : ''}>
    <button type="submit" class="menu-item ${opts.danger ? 'danger' : ''}" role="menuitem">${label}</button>
  </form>`;
  return html`<div class="profile-actions" id="pf-actions">
    ${rel.blocking ? html`<span class="muted text-sm">${t('settings.blocking')}</span>` : rel.muting ? html`<span class="muted text-sm">${t('settings.muting')}</span>` : ''}
    ${rel.blocking ? '' : followButton(ctx, accountId, rel)}
    <span class="boost-wrap" x-data="{ open: false }" @click.outside="open = false" @keydown.escape="open = false" @closemenus.document="open = false">
      <button type="button" class="chip" aria-haspopup="menu" :aria-expanded="open" aria-label="${t('status.more')}" @click="open = !open">…</button>
      <div class="menu boost-menu profile-menu" role="menu" x-show="open" x-cloak>
        <a class="menu-item" role="menuitem" href="/accounts/${accountId}/lists">${t('lists.addTo')}</a>
        ${act(rel.muting ? 'unmute' : 'mute', t(rel.muting ? 'profile.unmute' : 'profile.mute'))}
        ${act(rel.blocking ? 'unblock' : 'block', t(rel.blocking ? 'profile.unblock' : 'profile.block'), { danger: !rel.blocking, confirm: rel.blocking ? undefined : t('profile.confirmBlock') })}
      </div>
    </span>
  </div>`;
}

// フォロー申請への答え。押したところ(通知の行、または申請の一行)だけを差し替える。
// 通知から来たときは、その通知の id も添える ── 答えたら通知は片づく(残すと、答えたボタンが出つづける)。
export function requestButtons(ctx: Ctx, accountId: string, notifId?: string): SafeHtml {
  const form = (verb: 'accept' | 'decline') => html`<form method="post" action="/requests/${accountId}/${verb}" in-place>
    ${notifId ? html`<input type="hidden" name="nf" value="${notifId}" />` : ''}
    <button type="submit" class="chip">${ctx.t(verb === 'accept' ? 'requests.approve' : 'requests.reject')}</button>
  </form>`;
  return html`<div class="request-actions">${form('accept')}${form('decline')}</div>`;
}

export function accountRow(ctx: Ctx, a: Account, rel: Relationship | null, me: Account | null): SafeHtml {
  return html`<article class="account-row">
    <a class="account-row-link" href="/@${a.acct}">
      ${avatar(a.avatar, nameOf(a))}
      <span class="stack-tight">
        <span class="display-name">${nameHtml(a)}</span>
        <span class="muted">@${a.acct}</span>
      </span>
    </a>
    ${rel && me && me.id !== a.id ? followButton(ctx, a.id, rel) : ''}
  </article>`;
}
