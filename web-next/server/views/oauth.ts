// SPDX-License-Identifier: AGPL-3.0-or-later
// /oauth/authorize の顔が三つ ── アカウントを選ぶ・許可を聞く・うまく進めなかったとき。
// 何を見せるかは、gateway の api が決める(routes/oauth.ts)。ここは、決まったものを絵にするだけ。
import type { Ctx } from '../http.ts';
import { html, type SafeHtml } from '../html.ts';
import type { TranslationKey } from '../i18n.ts';
import { layout } from './layout.ts';

// 同意の頁だけは、form-action を立てない。この頁の「いいよ」は、外のアプリの custom scheme
// (例 cx-c3-toot://…)へ 303 で戻すのが仕事で、WebKit(Safari/iOS)は form-action を、送信のあとの
// 戻り先にまで当てる ── 立てると、Toot! などの webview が戻りを掴めず「いいよ」で先に進めない。
// (Chrome 系は戻り先を見ない。)ほかの守り(object / base / frame)は、残す。
export const CONSENT_CSP = "object-src 'none'; base-uri 'none'; frame-ancestors 'self'";

// api が名前で渡してくる権限を、その人のことばへ。知らない名前は、そのまま見せて「説明はまだ」と置く。
const SCOPES: Record<string, [TranslationKey, TranslationKey]> = {
  read: ['oauth.scope.read', 'oauth.scope.read.d'],
  write: ['oauth.scope.write', 'oauth.scope.write.d'],
  follow: ['oauth.scope.follow', 'oauth.scope.follow.d'],
  push: ['oauth.scope.push', 'oauth.scope.push.d'],
  'read:accounts': ['oauth.scope.readAccounts', 'oauth.scope.readAccounts.d'],
  'read:statuses': ['oauth.scope.readStatuses', 'oauth.scope.readStatuses.d'],
  'read:notifications': ['oauth.scope.readNotifications', 'oauth.scope.readNotifications.d'],
  'read:follows': ['oauth.scope.readFollows', 'oauth.scope.readFollows.d'],
  'write:statuses': ['oauth.scope.writeStatuses', 'oauth.scope.writeStatuses.d'],
  'write:media': ['oauth.scope.writeMedia', 'oauth.scope.writeMedia.d'],
  'write:accounts': ['oauth.scope.writeAccounts', 'oauth.scope.writeAccounts.d'],
  'write:follows': ['oauth.scope.writeFollows', 'oauth.scope.writeFollows.d'],
  'write:notifications': ['oauth.scope.writeNotifications', 'oauth.scope.writeNotifications.d']
};

export type Asked = { client_id: string; redirect_uri: string; scope: string; state: string };

export function pickPage(ctx: Ctx, accounts: { id: number; username: string }[], asked: URLSearchParams): SafeHtml {
  const t = ctx.t;
  // 選んだら、同じ問いに choose=<id> を足して戻る(api が、選んだ人を先頭にして答える)。
  const choose = (id: number) => `/oauth/authorize?${new URLSearchParams([...asked, ['choose', String(id)]])}`;
  return layout(ctx, {
    title: t('oauth.pickTitle'),
    entrance: true,
    body: html`<div class="measure stack">
      <section class="hero">
        <h1>${t('oauth.pickTitle')}</h1>
        <p class="tagline">${t('oauth.pickLead')}</p>
      </section>
      <div class="stack">
        ${accounts.map((a) => html`<a class="btn px-6 py-2" href="${choose(a.id)}">@${a.username}</a>`)}
      </div>
    </div>`
  });
}

export function consentPage(ctx: Ctx, app: { name: string }, scopes: string[], asked: Asked): SafeHtml {
  const t = ctx.t;
  return layout(ctx, {
    title: t('oauth.consentTitle', { app: app.name }),
    entrance: true,
    body: html`<div class="measure stack">
      <section class="hero">
        <h1>${t('oauth.consentTitle', { app: app.name })}</h1>
        <p class="tagline">${t('oauth.consentLead')}</p>
      </section>
      <ul class="scope-list">
        ${scopes.map((s) => {
          const keys = SCOPES[s];
          return keys
            ? html`<li><strong>${t(keys[0])}</strong> — ${t(keys[1])}</li>`
            : html`<li><strong>${s}</strong> — ${t('oauth.scope.unknown')}</li>`;
        })}
      </ul>
      <p class="prose-small">${t('oauth.consentBack', { to: asked.redirect_uri })}</p>
      <form class="form stack" method="post" action="/oauth/authorize">
        <input type="hidden" name="client_id" value="${asked.client_id}" />
        <input type="hidden" name="redirect_uri" value="${asked.redirect_uri}" />
        <input type="hidden" name="scope" value="${asked.scope}" />
        <input type="hidden" name="state" value="${asked.state}" />
        <button type="submit" class="btn px-6 py-2">${t('oauth.consentYes')}</button>
      </form>
      <p class="prose-small"><a href="/">${t('oauth.consentNo')}</a></p>
    </div>`
  });
}

// うまく進めなかったとき。理由は api のことば(英語の短い言い切り)をそのまま添える ── 外のアプリを作る人が読むため。
export function problemPage(ctx: Ctx, error: string, detail: string, unavailable: boolean): SafeHtml {
  const t = ctx.t;
  return layout(ctx, {
    title: t('oauth.problemTitle'),
    entrance: true,
    body: html`<div class="measure stack">
      <section class="hero">
        <h1>${t(unavailable ? 'oauth.unavailable' : 'oauth.problemTitle')}</h1>
      </section>
      ${unavailable ? '' : html`<p class="prose-small"><code>${error}</code>${detail ? html` — ${detail}` : ''}</p>`}
      <p class="prose-small"><a href="/">${t('common.backToTop')}</a></p>
    </div>`
  });
}
