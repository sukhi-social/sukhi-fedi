// SPDX-License-Identifier: AGPL-3.0-or-later
// メールのお願い。メールの確認が済んでいない人にだけ、頁の先頭(流れの中)に、小さなカードがそっと出る。
// 浮かせない ── 浮かせると、下にあるものを覆ってしまう。来たときに一度目に入って、読み進めれば流れて消える。
//   GET  /nudge          置き場(layout の <div up-defer>)から来る。出すか、出さないか、をここで決める
//   POST /nudge/send     メールアドレスへコードを送る(「もう一度送る」もここ)
//   POST /nudge/confirm  コードを確かめる
//   POST /nudge/later    「あとで」 ── 3 日静かに。二度目からは、30 日の静けさも選べる
//   POST /nudge/quiet    「しばらく静かにする」 ── 30 日
// どれも、置き場(#email-nudge)を丸ごと返す。いつ出すか・静かさの覚えかたは server/nudge.ts 一か所。
// メールの変更は gateway の cookie 専用の口(settings/email/*)。cookie が無い人には、入力欄ではなく「入りなおして」。

import { gwCookie, type CookieReply } from '../gateway.ts';
import { html, type SafeHtml } from '../html.ts';
import { ok, redirect, route, type Ctx } from '../http.ts';
import { LONG_SNOOZE_MS, NUDGE_ID, SNOOZE_MS, quietOf, snooze, snoozed } from '../nudge.ts';
import { saveSession } from '../session.ts';
import { backOr } from './shared.ts';
import { explain, type Auth } from './security.ts';

const good = (r: CookieReply<unknown>) => r.status >= 200 && r.status < 300;
const target = `#${NUDGE_ID}`;

// 置き場。中身が無ければ、空のまま ── 何も出ない。
const slot = (inner?: SafeHtml): SafeHtml => html`<div id="${NUDGE_ID}">${inner ?? ''}</div>`;

// カードの枠。Cloudflare にメールのアドレスを書き換えられないよう email_off で囲む(入力欄に、本人のアドレスが入る)。
// 「閉じる」「3 日後でいい」は、サーバへは行かず、その場で畳むだけ。
const card = (inner: SafeHtml): SafeHtml =>
  slot(html`<!--email_off--><aside class="email-nudge" role="status" aria-live="polite" x-data="{ open: true }" x-show="open">${inner}</aside><!--/email_off-->`);

const errorLine = (error?: string): SafeHtml => (error ? html`<p class="error" role="alert">${error}</p>` : html``);

function askStep(ctx: Ctx, a: Auth, o: { error?: string; email?: string } = {}): SafeHtml {
  const t = ctx.t;
  const lead = html`<p class="nudge-lead">${a.email ? t('nudge.bodyUnverified') : t('nudge.bodyNone')}</p>`;
  // cookie が無い人(ずっと前に入った人など)は、入力欄の代わりに「入りなおして」。
  if (!a.manageable) {
    return html`${lead}<p class="nudge-small">${t('security.needRelogin')}</p>
      <div class="nudge-actions">
        <a class="btn px-3 py-1" href="/login">${t('security.reloginLink')}</a>
        <form method="post" action="/nudge/later" in-place up-target="${target}"><button type="submit" class="btn secondary px-3 py-1">${t('nudge.later')}</button></form>
      </div>`;
  }
  return html`${lead}
    <form class="nudge-form" method="post" action="/nudge/send" in-place up-target="${target}">
      <input type="email" name="email" value="${o.email ?? a.email ?? ''}" autocomplete="email" placeholder="${t('signup.email')}" required />
      <div class="nudge-actions">
        <button type="submit" class="btn px-3 py-1">${t('login.sendCode')}</button>
        <button type="submit" class="btn secondary px-3 py-1" formaction="/nudge/later" formnovalidate>${t('nudge.later')}</button>
      </div>
    </form>
    ${errorLine(o.error)}`;
}

function codeStep(ctx: Ctx, email: string, error?: string): SafeHtml {
  const t = ctx.t;
  return html`<form class="nudge-form" method="post" action="/nudge/confirm" in-place up-target="${target}">
      <p class="nudge-small">${t('security.codeSent')}</p>
      <input type="hidden" name="email" value="${email}" />
      <input type="text" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" placeholder="${t('login.code')}" required />
      <div class="nudge-actions">
        <button type="submit" class="btn px-3 py-1">${t('security.confirm')}</button>
        <button type="submit" class="btn secondary px-3 py-1" formaction="/nudge/send" formnovalidate>${t('login.sendAgain')}</button>
      </div>
    </form>
    ${errorLine(error)}`;
}

const doneStep = (ctx: Ctx): SafeHtml => html`<p>${ctx.t('nudge.thanks')}</p>
  <div class="nudge-actions"><button type="button" class="btn px-3 py-1" @click="open = false">${ctx.t('nudge.close')}</button></div>`;

// 二度目の「あとで」。3 日の静けさは、もう置いてある ── ここで選べるのは、もっと長くするか、そのままか。
const longStep = (ctx: Ctx): SafeHtml => html`<p class="nudge-lead">${ctx.t('nudge.longOffer')}</p>
  <div class="nudge-actions">
    <form method="post" action="/nudge/quiet" in-place up-target="${target}"><button type="submit" class="btn px-3 py-1">${ctx.t('nudge.longQuiet')}</button></form>
    <button type="button" class="btn secondary px-3 py-1" @click="open = false">${ctx.t('nudge.longKeep')}</button>
  </div>`;

// いまの状態。読めなければ null(出さない ── 次の機会に)。届かなかったとき(TypeError)も、出さない。
async function stateOf(ctx: Ctx): Promise<Auth | null> {
  try {
    const r = await gwCookie<Auth>(ctx, 'GET', '/auth/state');
    return r.status === 200 ? (r.body as Auth) : null;
  } catch (e) {
    if (e instanceof TypeError) return null;
    throw e;
  }
}

function markVerified(ctx: Ctx): void {
  const s = ctx.sess();
  s.emailOk = true;
  saveSession(s);
}

// 失敗のことば。cookie が切れていたとき(401)は「入りなおして」。
const why = (ctx: Ctx, r: CookieReply<unknown>): string => (r.status === 401 ? ctx.t('security.needRelogin') : explain(ctx, r.body.error, false));

route('GET', '/nudge', async (ctx) => {
  // 置き場から来る以外(アドレスを直に開いたとき)は、頁の断片だけ返しても仕方がない。
  if (!ctx.isUp) return redirect('/');
  if (!ctx.session?.token || ctx.session.emailOk || snoozed(ctx)) return ok(slot());
  const a = await stateOf(ctx);
  if (!a) return ok(slot());
  if (a.email_verified) {
    markVerified(ctx);
    return ok(slot());
  }
  return ok(card(askStep(ctx, a)));
});

route('POST', '/nudge/send', async (ctx) => {
  const email = String((await ctx.form()).get('email') ?? '').trim();
  const r = await gwCookie(ctx, 'POST', '/settings/email/request', { email });
  if (good(r)) return backOr(ctx, card(codeStep(ctx, email)));
  const a = await stateOf(ctx);
  return backOr(ctx, a ? card(askStep(ctx, a, { error: why(ctx, r), email })) : slot());
});

route('POST', '/nudge/confirm', async (ctx) => {
  const f = await ctx.form();
  const r = await gwCookie(ctx, 'POST', '/settings/email/confirm', { code: String(f.get('code') ?? '').trim() });
  if (good(r)) {
    markVerified(ctx);
    return backOr(ctx, card(doneStep(ctx)));
  }
  return backOr(ctx, card(codeStep(ctx, String(f.get('email') ?? ''), why(ctx, r))));
});

route('POST', '/nudge/later', async (ctx) => {
  const n = quietOf(ctx).count + 1;
  snooze(ctx, SNOOZE_MS, n);
  return backOr(ctx, n >= 2 ? card(longStep(ctx)) : slot());
});

route('POST', '/nudge/quiet', async (ctx) => {
  snooze(ctx, LONG_SNOOZE_MS, quietOf(ctx).count);
  return backOr(ctx, slot());
});
