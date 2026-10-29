// 人の一行と、フォローのボタン。AccountRow.svelte / FollowButton.svelte の置き換え。
// フォロワーの数は、どこにも出さない。

import { html, raw, type SafeHtml } from '../html.ts';
import type { Ctx } from '../http.ts';
import type { Account, Relationship } from '../types.ts';
import { renderEmojis } from '../emoji.ts';
import { phrase } from '../phrase.ts';
import { avatar } from './parts.ts';

export const nameOf = (a: Account) => a.display_name || a.username;
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
