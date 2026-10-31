// SPDX-License-Identifier: AGPL-3.0-or-later
// ログインと安全: メールアドレス・アプリの二段階認証(TOTP)・パスキー・入っている端末・あいことば。
// 元の web の /settings/security と /settings/password の置き換え。
//
// これらの口は、gateway では「ブラウザの session_token cookie」だけを見る(bearer は第三者のアプリにも
// 渡るので、ログインの要素には触らせない)。この郵便局はその cookie を一本だけ添えて呼ぶ(gwCookie)。
// cookie が無い・切れているときは、フォームを出さずに「入りなおしてください」を出す。
//
// 要素を外す操作(二段階認証をやめる・パスキーを消す・端末を出す・確認ずみのメールを替える)は、本人確認つき。
// あいことばを持つ人は合言葉、持たない人は「確認のコードを送る → 6 桁」。1 か所(reauthField)で出す。
// パスキーの登録だけは、ブラウザの認証器を呼ぶので、public/js/app.js の小さな部品が受け持つ
// (サーバは、その部品に options を渡し、できあがりを gateway に渡すだけ)。

import { renderSVG } from 'uqr';
import { endSession, gwCookie, type CookieReply } from '../gateway.ts';
import { html, raw, type SafeHtml } from '../html.ts';
import { ok, redirect, route, type Ctx, type Reply } from '../http.ts';
import type { TranslationKey } from '../i18n.ts';
import { deviceLabel, placeLabel } from '../device.ts';
import { timeWords } from '../time.ts';
import { layout } from '../views/layout.ts';
import { needMe } from './shared.ts';

type Auth = {
  manageable: boolean;
  acct: string;
  email: string | null;
  email_verified: boolean;
  has_password: boolean;
  totp_enabled: boolean;
  totp_pending: boolean;
  passkeys: { id: number; nickname: string | null; created_at: string; last_used_at: string | null }[];
};

type DeviceSession = {
  id: number;
  ip: string;
  user_agent: string | null;
  created_at: string;
  last_seen_at: string | null;
  current: boolean;
};

type Where = 'email' | 'totp' | 'passkey' | 'session' | 'password';

// gateway の error ことば → こちらで言えることば。知らないものは「うまく届きませんでした」。
const ERRORS: Record<string, TranslationKey> = {
  no_verified_email: 'security.noVerifiedEmail',
  password: 'security.wrongPassword',
  email: 'security.emailInvalid',
  email_taken: 'security.emailTaken',
  code: 'security.codeWrong',
  expired: 'security.codeExpired',
  rate_limited: 'login.rateLimited',
  too_many_attempts: 'login.rateLimited',
  send_failed: 'security.sendFailed',
  already_registered: 'security.passkeyDup'
};

function explain(ctx: Ctx, code: string | undefined, hasPassword: boolean): string {
  const t = ctx.t;
  if (code === 'reauth') return hasPassword ? t('security.wrongPassword') : t('security.reauthFailed');
  return t(ERRORS[code ?? ''] ?? 'common.deliverFailed');
}

const str = (f: FormData, k: string) => String(f.get(k) ?? '');

// 戻ったとき、開いておく折りたたみの印。URL に載せるので、形を決めておく。
const OPEN = /^[a-z0-9-]{1,32}$/;
const openOf = (v: string) => (OPEN.test(v) ? v : '');

// 本人確認の中身。フォームにあるものだけ送る(gateway が、あいことばの有無で、どちらを見るか決める)。
function reauthOf(f: FormData): { password?: string; reauth_code?: string } {
  const out: { password?: string; reauth_code?: string } = {};
  const password = str(f, 'password');
  const code = str(f, 'reauth_code').trim();
  if (password) out.password = password;
  if (code) out.reauth_code = code;
  return out;
}

async function readJson(ctx: Ctx): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of ctx.req) {
    size += (c as Buffer).length;
    if (size > 64 * 1024) return {};
    chunks.push(c as Buffer);
  }
  try {
    const v = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

const json = (body: unknown, status = 200): Reply =>
  ok(JSON.stringify(body), status, { 'content-type': 'application/json; charset=utf-8' });

// ── 本人確認の欄 ──────────────────────────────────────────────
// 外す操作の形(<form>)の中に置く。`open` は、コードを送って戻ったとき、同じ折りたたみを開いておくための印。
function reauthField(ctx: Ctx, a: Auth, open: string): SafeHtml {
  const t = ctx.t;
  if (a.has_password) {
    return html`<input type="hidden" name="open" value="${open}" />
      <label class="stack-tight">
        <span>${t('security.passwordToConfirm')}</span>
        <input type="password" name="password" autocomplete="current-password" required />
      </label>`;
  }
  return html`<input type="hidden" name="open" value="${open}" />
    <div class="stack-tight">
      <span>${t('security.reauthLabel')}</span>
      <p class="muted text-sm">${t('security.reauthHelp')}</p>
      <input type="text" name="reauth_code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" placeholder="${t('login.code')}" required />
      <div><button type="submit" class="chip" formaction="/settings/security/reauth" formnovalidate>${t('security.reauthSend')}</button></div>
    </div>`;
}

// ── 頁 ──────────────────────────────────────────────────────
type Opts = {
  // 失敗の知らせ。出す節と、gateway の error ことば。
  error?: { where: Where; code?: string };
  // 認証アプリの登録の途中(QR と、手で入れる鍵)。
  totp?: { secret: string; otpauth: string };
  // メールのコードの欄を出す(送ったあと)。emailTo は、入力に残すアドレス。
  emailStep?: boolean;
  emailTo?: string;
  open?: string;
  status?: number;
};

async function securityPage(ctx: Ctx, o: Opts = {}): Promise<Reply> {
  const t = ctx.t;
  const me = await needMe(ctx);
  const state = await gwCookie<Auth>(ctx, 'GET', '/auth/state');
  const a = state.status === 200 ? (state.body as Auth) : null;
  const head = html`<header class="timeline page-head"><h1>${t('security.title')}</h1></header>`;
  const back = html`<p class="prose-small"><a class="chip" href="/settings">${t('security.backToSettings')}</a></p>`;
  const wrap = (inner: SafeHtml, status = 200) =>
    ok(layout(ctx, { title: t('security.title'), me, body: html`${head}<div class="timeline stack">${inner}</div>` }), status);

  if (!a || !a.manageable) {
    return wrap(
      html`<section class="stack"><p>${t('security.needRelogin')}</p><p><a class="chip" href="/login">${t('security.reloginLink')}</a></p></section>${back}`
    );
  }
  // 入れ替えて使っているとき: cookie の持ち主と、いま見せているアカウントが違うと、変えたいほうと別の設定が変わってしまう。
  if (a.acct !== me.username) {
    return wrap(
      html`<section class="stack"><p>${t('security.accountMismatch', { acct: a.acct })}</p><p><a class="chip" href="/login?next=/settings/security">${t('security.reloginLink')}</a></p></section>${back}`
    );
  }

  const sessions = await gwCookie<{ sessions: DeviceSession[] }>(ctx, 'GET', '/settings/sessions');
  const devices = sessions.status === 200 ? (sessions.body.sessions ?? []) : [];
  const sessionsFailed = sessions.status !== 200;

  const open = o.open ?? '';
  const err = (where: Where) =>
    o.error?.where === where ? html`<p class="error" role="alert">${explain(ctx, o.error.code, a.has_password)}</p>` : '';
  const fold = (key: string, label: string, form: SafeHtml) =>
    html`<details ${open === key ? 'open' : ''}><summary class="chip">${label}</summary>${form}</details>`;
  const when = (iso: string | null) => (iso ? timeWords(iso, ctx.locale) : '—');

  // ── メール ──
  const emailLabel = a.email ? (a.email_verified ? t('security.emailChange') : t('security.emailVerify')) : t('security.emailSet');
  const emailForm = html`<form class="stack" method="post" action="/settings/security/email">
    <label class="stack-tight">
      <span>${t('security.emailTitle')}</span>
      <input type="email" name="email" value="${o.emailTo ?? a.email ?? ''}" autocomplete="email" required />
    </label>
    ${a.email_verified ? reauthField(ctx, a, 'email') : ''}
    <div><button type="submit" class="btn px-6 py-2">${t('login.sendCode')}</button></div>
  </form>`;
  const emailCodeForm = html`<form class="stack" method="post" action="/settings/security/email/confirm">
    <p class="muted text-sm">${t('security.codeSent')}</p>
    <label class="stack-tight">
      <span>${t('login.code')}</span>
      <input type="text" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" required />
    </label>
    <div class="hstack" style="--gap: var(--space-3)">
      <button type="submit" class="btn px-6 py-2">${t('security.confirm')}</button>
      <a class="chip" href="/settings/security?open=email">${t('login.sendAgain')}</a>
    </div>
  </form>`;
  const emailSection = html`<section class="stack">
    <h2 class="text-base">${t('security.emailTitle')}</h2>
    ${a.email
      ? html`<p><code>${a.email}</code> <span class="muted">${a.email_verified ? t('security.emailVerified') : t('security.emailUnverified')}</span></p>`
      : html`<p class="muted">${t('security.emailNone')}</p>`}
    ${o.emailStep ? emailCodeForm : fold('email', emailLabel, emailForm)}
    ${err('email')}
  </section>`;

  // ── アプリで二段階認証 ──
  let totpBody: SafeHtml;
  if (a.totp_enabled) {
    totpBody = html`<p class="muted">${t('security.totpOn')}</p>
      ${fold(
        'totp',
        t('security.totpDisable'),
        html`<form class="stack" method="post" action="/settings/security/totp/disable">
          ${reauthField(ctx, a, 'totp')}
          <div><button type="submit" class="btn px-6 py-2">${t('security.totpDisable')}</button></div>
        </form>`
      )}`;
  } else if (o.totp) {
    totpBody = html`<p class="prose-small">${t('security.totpScan')}</p>
      <div class="qr" role="img" aria-label="QR">${raw(renderSVG(o.totp.otpauth))}</div>
      <p class="prose-small">${t('security.totpSecret')}: <code>${o.totp.secret}</code></p>
      <form class="stack" method="post" action="/settings/security/totp/enable">
        <input type="hidden" name="secret" value="${o.totp.secret}" />
        <input type="hidden" name="otpauth" value="${o.totp.otpauth}" />
        <label class="stack-tight">
          <span>${t('security.totpConfirmHelp')}</span>
          <input type="text" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" required />
        </label>
        <div><button type="submit" class="btn px-6 py-2">${t('security.totpEnable')}</button></div>
      </form>`;
  } else {
    totpBody = html`<p class="muted">${t('security.totpOff')}</p>
      <form method="post" action="/settings/security/totp/setup"><button type="submit" class="chip">${t('security.totpStart')}</button></form>`;
  }
  const totpSection = html`<section class="stack"><h2 class="text-base">${t('security.totpTitle')}</h2>${totpBody}${err('totp')}</section>`;

  // ── パスキー ──
  const passkeySection = html`<section class="stack">
    <h2 class="text-base">${t('security.passkeysTitle')}</h2>
    ${a.passkeys.length === 0
      ? html`<p class="muted">${t('security.passkeysNone')}</p>`
      : html`<ul class="rows">
          ${a.passkeys.map(
            (pk) => html`<li>
              <span>${pk.nickname ?? t('security.passkeyUnnamed')}</span>
              <span class="muted text-sm">${t('security.lastUsed')}: ${when(pk.last_used_at)}</span>
              ${fold(
                `pk-${pk.id}`,
                t('security.passkeyDelete'),
                html`<form class="stack" method="post" action="/settings/security/passkeys/${pk.id}/delete">
                  ${reauthField(ctx, a, `pk-${pk.id}`)}
                  <div><button type="submit" class="btn px-6 py-2">${t('security.passkeyDelete')}</button></div>
                </form>`
              )}
            </li>`
          )}
        </ul>`}
    <form class="stack" data-passkey-add hidden up-submit="false" method="post" action="/settings/security">
      <label class="stack-tight">
        <span>${t('security.passkeyNickname')}</span>
        <input type="text" name="nickname" maxlength="50" />
      </label>
      <div><button type="submit" class="btn px-6 py-2">${t('security.passkeyAdd')}</button></div>
      <p class="error" role="alert" data-passkey-error hidden></p>
    </form>
    <p class="prose-small" data-passkey-unsupported>${t('security.passkeyUnsupported')}</p>
    ${err('passkey')}
  </section>`;

  // ── 入っている端末 ──
  const sessionSection = html`<section class="stack">
    <h2 class="text-base">${t('security.sessionsTitle')}</h2>
    <p class="prose-small">${t('security.sessionsHelp')}</p>
    ${sessionsFailed
      ? html`<p class="error">${t('common.readFailed')}</p>`
      : devices.length === 0
        ? html`<p class="muted">${t('security.sessionsNone')}</p>`
        : html`<ul class="rows">
            ${devices.map((s) => {
              const place = placeLabel(s.ip);
              const meta = [place ? `${t('security.sessionWhere')}: ${place}` : '', `${t('security.lastUsed')}: ${when(s.last_seen_at)}`]
                .filter(Boolean)
                .join(' · ');
              // 出す操作は、ほかの端末だけ。この端末は、ふだんのサインアウト(メニュー)で出る。
              return html`<li>
                <span>${deviceLabel(s.user_agent) ?? t('security.sessionUnknownDevice')}${s.current ? html` <span class="muted">${t('security.sessionCurrent')}</span>` : ''}</span>
                <span class="muted text-sm">${meta}</span>
                ${s.current
                  ? ''
                  : fold(
                      `sess-${s.id}`,
                      t('security.sessionRevoke'),
                      html`<form class="stack" method="post" action="/settings/security/sessions/${s.id}/revoke">
                        ${reauthField(ctx, a, `sess-${s.id}`)}
                        <div><button type="submit" class="btn px-6 py-2">${t('security.sessionRevoke')}</button></div>
                      </form>`
                    )}
              </li>`;
            })}
          </ul>`}
    ${err('session')}
  </section>`;

  // ── あいことば(レガシー) ──
  const passwordSection = html`<section class="stack">
    <h2 class="text-base">${t('security.passwordTitle')}</h2>
    ${a.has_password
      ? html`<p class="muted">${t('security.passwordOn')}</p>
          <div class="hstack" style="--gap: var(--space-2)">
            <a class="chip" href="/settings/password">${t('settings.changePassword')}</a>
          </div>
          ${a.email_verified
            ? fold(
            'pw-remove',
            t('security.passwordRemove'),
            html`<form class="stack" method="post" action="/settings/security/password/remove">
              <p class="prose-small">${t('security.passwordRemoveHelp')}</p>
              <input type="hidden" name="open" value="pw-remove" />
              <label class="stack-tight">
                <span>${t('security.passwordToConfirm')}</span>
                <input type="password" name="password" autocomplete="current-password" required />
              </label>
              <div><button type="submit" class="btn px-6 py-2">${t('security.passwordRemove')}</button></div>
            </form>`
          )
            : html`<p class="prose-small">${t('security.passwordRemoveNeedsEmail')}</p>`}`
      : html`<p class="muted">${t('security.passwordNone')}</p>
          <p><a class="chip" href="/settings/password">${t('security.passwordSet')}</a></p>`}
    ${err('password')}
  </section>`;

  return wrap(
    html`<div class="settings-form">${emailSection}${totpSection}${passkeySection}${sessionSection}${passwordSection}</div>${back}`,
    o.status ?? 200
  );
}

// ── 失敗の返しかた ───────────────────────────────────────────
// gateway が 2xx でなかったとき: その節に、ことばを添えて、同じ頁を返す。
function failed(ctx: Ctx, r: CookieReply, where: Where, o: Opts = {}): Promise<Reply> {
  return securityPage(ctx, { ...o, error: { where, code: r.body.error }, status: r.status === 429 ? 429 : 422 });
}
const good = (r: CookieReply) => r.status >= 200 && r.status < 300;

route('GET', '/settings/security', async (ctx) => {
  const step = ctx.url.searchParams.get('step');
  const to = ctx.url.searchParams.get('to') ?? undefined;
  return securityPage(ctx, { open: openOf(ctx.url.searchParams.get('open') ?? ''), emailStep: step === 'email', emailTo: to });
});

// 本人確認のコードを、確認ずみのメールへ送る。送ったら、押した折りたたみを開いて戻る。
route('POST', '/settings/security/reauth', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const open = openOf(str(f, 'open'));
  const a = await gwCookie<Auth>(ctx, 'GET', '/auth/state');
  const r = await gwCookie(ctx, 'POST', '/settings/reauth/request', {});
  if (good(r)) ctx.flash('notice', ctx.t('security.codeSent'));
  else ctx.flash('error', explain(ctx, r.body.error, a.status === 200 && !!(a.body as Auth).has_password));
  return redirect(`/settings/security${open ? `?open=${open}` : ''}`);
});

// ── メール ──
route('POST', '/settings/security/email', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const email = str(f, 'email').trim();
  const r = await gwCookie(ctx, 'POST', '/settings/email/request', { email, ...reauthOf(f) });
  if (good(r)) return redirect(`/settings/security?step=email&to=${encodeURIComponent(email)}`);
  return failed(ctx, r, 'email', { open: 'email', emailTo: email });
});

route('POST', '/settings/security/email/confirm', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const r = await gwCookie(ctx, 'POST', '/settings/email/confirm', { code: str(f, 'code').trim() });
  if (good(r)) {
    ctx.flash('notice', ctx.t('settings.saved'));
    return redirect('/settings/security');
  }
  // 入れなおしやすいよう、コードの欄のまま戻す(送り先は、gateway が覚えている)。
  return failed(ctx, r, 'email', { emailStep: true });
});

// ── 二段階認証 ──
route('POST', '/settings/security/totp/setup', async (ctx) => {
  await needMe(ctx);
  const r = await gwCookie<{ secret: string; otpauth: string }>(ctx, 'POST', '/settings/totp/setup', {});
  if (good(r)) return securityPage(ctx, { totp: { secret: r.body.secret, otpauth: r.body.otpauth } });
  return failed(ctx, r, 'totp');
});

route('POST', '/settings/security/totp/enable', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const r = await gwCookie(ctx, 'POST', '/settings/totp/enable', { code: str(f, 'code').trim() });
  if (good(r)) {
    ctx.flash('notice', ctx.t('settings.saved'));
    return redirect('/settings/security');
  }
  // 鍵は作りなおさない(作りなおすと、アプリに入れたものが古くなる)。同じ QR のまま、もう一度。
  const secret = str(f, 'secret');
  const otpauth = str(f, 'otpauth');
  return failed(ctx, r, 'totp', secret && otpauth ? { totp: { secret, otpauth } } : {});
});

route('POST', '/settings/security/totp/disable', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const r = await gwCookie(ctx, 'POST', '/settings/totp/disable', reauthOf(f));
  if (good(r)) {
    ctx.flash('notice', ctx.t('settings.saved'));
    return redirect('/settings/security');
  }
  return failed(ctx, r, 'totp', { open: 'totp' });
});

// ── パスキー ──
// 登録は、ブラウザの認証器を呼ぶので、public/js/app.js の部品が、この二つを順に叩く。
route('POST', '/settings/security/passkeys/options', async (ctx) => {
  await needMe(ctx);
  const r = await gwCookie(ctx, 'POST', '/settings/passkeys/options', {});
  if (good(r)) return json(r.body);
  return json({ error: r.body.error ?? 'failed', message: explain(ctx, r.body.error, true) }, r.status);
});

route('POST', '/settings/security/passkeys', async (ctx) => {
  await needMe(ctx);
  const body = await readJson(ctx);
  const r = await gwCookie(ctx, 'POST', '/settings/passkeys', body);
  if (good(r)) {
    ctx.flash('notice', ctx.t('settings.saved'));
    return json({ ok: true });
  }
  return json({ error: r.body.error ?? 'failed', message: explain(ctx, r.body.error, true) }, r.status);
});

route('POST', '/settings/security/passkeys/:id/delete', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const r = await gwCookie(ctx, 'POST', `/settings/passkeys/${encodeURIComponent(ctx.params.id)}/delete`, reauthOf(f));
  if (good(r)) {
    ctx.flash('notice', ctx.t('settings.saved'));
    return redirect('/settings/security');
  }
  return failed(ctx, r, 'passkey', { open: `pk-${openOf(ctx.params.id)}` });
});

// ── 端末 ──
route('POST', '/settings/security/sessions/:id/revoke', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const r = await gwCookie(ctx, 'POST', `/settings/sessions/${encodeURIComponent(ctx.params.id)}/revoke`, reauthOf(f));
  if (!good(r)) return failed(ctx, r, 'session', { open: `sess-${openOf(ctx.params.id)}` });
  // この端末を出したなら、この郵便局の預かりも閉じる(cookie はもう効かない)。
  if (str(f, 'current') === '1') {
    for (const c of r.setCookies) ctx.cookies.push(c);
    await endSession(ctx);
    return redirect('/');
  }
  ctx.flash('notice', ctx.t('settings.saved'));
  return redirect('/settings/security');
});

// ── あいことば ──
route('POST', '/settings/security/password/remove', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const r = await gwCookie(ctx, 'POST', '/settings/password/remove', { password: str(f, 'password') });
  if (good(r)) {
    ctx.flash('notice', ctx.t('settings.saved'));
    return redirect('/settings/security');
  }
  return failed(ctx, r, 'password', { open: 'pw-remove' });
});

// ── あいことばを設定する・変える ──────────────────────────────
// まだ持っていない人 →「設定する」(いまの合言葉は要らず、入ったまま)。
// 持っている人 →「変える」(gateway が、ぜんぶの端末を出す。この郵便局の預かりも閉じて、入りなおしてもらう)。
const PASSWORD_ERRORS: Record<string, TranslationKey> = {
  current: 'password.errCurrent',
  mismatch: 'password.errMismatch',
  short: 'password.errShort',
  unauthorized: 'password.errAuth'
};

async function passwordPage(ctx: Ctx, error?: string, status = 200): Promise<Reply> {
  const t = ctx.t;
  const me = await needMe(ctx);
  const state = await gwCookie<Auth>(ctx, 'GET', '/auth/state');
  // 読めなくても進められる(正しい側の判定は gateway が持っている)。変えるほうの形のまま。
  const hasPassword = state.status === 200 ? (state.body as Auth).has_password : true;
  const body = html`<section class="hero">
      <h1>${hasPassword ? t('password.title') : t('password.setTitle')}</h1>
      <p class="tagline">${t('password.tagline', { username: me.username })}</p>
    </section>
    <div class="timeline stack">
      ${hasPassword ? '' : html`<p class="prose-small">${t('password.setHelp')}</p>`}
      ${error ? html`<p class="error" role="alert">${error}</p>` : ''}
      <form class="settings-form" method="post" action="/settings/password">
        ${hasPassword
          ? html`<label class="stack-tight">
              <span>${t('password.current')}</span>
              <input type="password" name="current_password" autocomplete="current-password" required />
            </label>`
          : ''}
        <label class="stack-tight">
          <span>${t('password.new')}</span>
          <input type="password" name="new_password" autocomplete="new-password" minlength="8" required />
        </label>
        <label class="stack-tight">
          <span>${t('password.confirm')}</span>
          <input type="password" name="confirm_password" autocomplete="new-password" minlength="8" required />
        </label>
        <div><button type="submit" class="btn primary px-6 py-2">${hasPassword ? t('password.submit') : t('password.setSubmit')}</button></div>
      </form>
      <p class="prose-small"><a class="chip" href="/settings/security">${t('security.backToSettings')}</a></p>
    </div>`;
  return ok(layout(ctx, { title: hasPassword ? t('password.title') : t('password.setTitle'), me, body }), status);
}

route('GET', '/settings/password', (ctx) => passwordPage(ctx));

route('POST', '/settings/password', async (ctx) => {
  const t = ctx.t;
  await needMe(ctx);
  const f = await ctx.form();
  const next = str(f, 'new_password');
  const confirm = str(f, 'confirm_password');
  if (next !== confirm) return passwordPage(ctx, t('password.errMismatch'), 422);

  const r = await gwCookie<{ initial?: boolean }>(ctx, 'POST', '/settings/password', {
    current_password: str(f, 'current_password'),
    new_password: next,
    confirm_password: confirm
  });
  if (!good(r)) {
    const key = PASSWORD_ERRORS[r.body.error ?? ''];
    return passwordPage(ctx, t(key ?? 'password.failed'), r.status === 401 ? 401 : 422);
  }

  if (r.body.initial) {
    // 初めての設定: 入ったまま。
    ctx.flash('notice', t('password.setDoneNotice'));
    return redirect('/settings/security');
  }
  // 変えた: gateway が、ぜんぶの端末を出した。ここの預かりも閉じて、入りなおしてもらう。
  for (const c of r.setCookies) ctx.cookies.push(c);
  await endSession(ctx);
  const body = html`<section class="hero"><h1>${t('password.doneTitle')}</h1></section>
    <p class="notice">${t('password.doneNotice')}</p>
    <p><a class="chip" href="/login">${t('login.title')}</a></p>`;
  return ok(layout(ctx, { title: t('password.doneTitle'), entrance: true, body }));
});
