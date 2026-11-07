// SPDX-License-Identifier: AGPL-3.0-or-later
// アカウントを閉じる。入るのと同じくらい易しく: 本人確認とボタン一回。理由は聞かず、引き止めない。
// 押してから一日は取り消せる(そのあいだ、連合には何も送らない。猶予の長さは gateway が持つ)。
// 本人確認は「ログインと安全」と同じ一か所(reauthField)で出し、gateway の cookie 専用の口を呼ぶ。

import { gwCookie, type CookieReply } from '../gateway.ts';
import { html, type SafeHtml } from '../html.ts';
import { ok, redirect, route, type Ctx, type Reply } from '../http.ts';
import { layout } from '../views/layout.ts';
import { explain, reauthField, reauthOf, type Auth } from './security.ts';
import { needMe } from './shared.ts';

type Close = { pending: { scheduled_for: string } | null };

const good = (r: CookieReply<unknown>) => r.status >= 200 && r.status < 300;

async function closePage(ctx: Ctx, o: { error?: string; status?: number } = {}): Promise<Reply> {
  const t = ctx.t;
  const me = await needMe(ctx);
  const [state, closing] = await Promise.all([
    gwCookie<Auth>(ctx, 'GET', '/auth/state'),
    gwCookie<Close>(ctx, 'GET', '/settings/close/status')
  ]);
  const a = state.status === 200 ? (state.body as Auth) : null;
  const flash = ctx.takeFlash();
  const head = html`<header class="timeline page-head"><h1>${t('close.title')}</h1></header>`;
  const back = html`<p class="prose-small"><a class="chip" href="/settings">${t('security.backToSettings')}</a></p>`;
  const wrap = (inner: SafeHtml, status = 200) =>
    ok(layout(ctx, { title: t('close.title'), me, body: html`${head}<div class="timeline stack">${inner}</div>` }), status);

  if (!a || !a.manageable) {
    return wrap(html`<section class="stack"><p>${t('security.needRelogin')}</p><p><a class="chip" href="/login">${t('security.reloginLink')}</a></p></section>${back}`);
  }
  // 入れ替えて使っているとき: cookie の持ち主と、いま見せているアカウントが違うと、別の人を閉じてしまう。
  if (a.acct !== me.username) {
    return wrap(html`<section class="stack"><p>${t('security.accountMismatch', { acct: a.acct })}</p><p><a class="chip" href="/login?next=/settings/close">${t('security.reloginLink')}</a></p></section>${back}`);
  }

  const pending = closing.status === 200 ? (closing.body as Close).pending : null;
  const at = pending
    ? new Intl.DateTimeFormat(ctx.locale, { dateStyle: 'medium', timeStyle: 'short', timeZone: ctx.tz }).format(new Date(pending.scheduled_for))
    : '';

  return wrap(
    html`${flash ? html`<p class="${flash.kind === 'error' ? 'error' : 'notice'}" role="status">${flash.text}</p>` : ''}
      <section class="stack">
        <p class="prose-small">${t('close.intro')}</p>
        <p class="prose-small">${t('close.what')}</p>
        <p class="prose-small">${t('close.handle')}</p>
        <p class="prose-small">${t('close.exportPre')}<a href="/settings/migration">${t('close.exportLink')}</a>${t('close.exportPost')}</p>
        <p class="prose-small">${t('close.mail')}</p>
        ${pending
          ? html`<p>${t('close.pending', { at })}</p>
              <p class="prose-small">${t('close.pendingHelp')}</p>
              <form method="post" action="/settings/close/cancel"><button type="submit" class="btn">${t('close.cancel')}</button></form>`
          : html`<form class="settings-form" method="post" action="/settings/close/request">
              ${reauthField(ctx, a, 'close', '/settings/close/reauth')}
              <div><button type="submit" class="btn">${t('close.request')}</button></div>
            </form>`}
        ${o.error ? html`<p class="error" role="alert">${o.error}</p>` : ''}
      </section>${back}`,
    o.status ?? 200
  );
}

route('GET', '/settings/close', (ctx) => closePage(ctx));

// 本人確認のコードを送る(あいことばを持たない人)。
route('POST', '/settings/close/reauth', async (ctx) => {
  await needMe(ctx);
  const a = await gwCookie<Auth>(ctx, 'GET', '/auth/state');
  const r = await gwCookie(ctx, 'POST', '/settings/reauth/request', {});
  if (good(r)) ctx.flash('notice', ctx.t('security.codeSent'));
  else ctx.flash('error', explain(ctx, r.body.error, a.status === 200 && !!(a.body as Auth).has_password));
  return redirect('/settings/close');
});

route('POST', '/settings/close/request', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const r = await gwCookie(ctx, 'POST', '/settings/close/request', reauthOf(f));
  if (good(r)) return redirect('/settings/close');
  const a = await gwCookie<Auth>(ctx, 'GET', '/auth/state');
  return closePage(ctx, { error: explain(ctx, r.body.error, a.status === 200 && !!(a.body as Auth).has_password), status: r.status === 429 ? 429 : 422 });
});

route('POST', '/settings/close/cancel', async (ctx) => {
  await needMe(ctx);
  const r = await gwCookie(ctx, 'POST', '/settings/close/cancel', {});
  if (good(r)) ctx.flash('notice', ctx.t('close.cancelled'));
  else ctx.flash('error', r.body.error === 'started' ? ctx.t('close.started') : ctx.t('common.deliverFailed'));
  return redirect('/settings/close');
});
