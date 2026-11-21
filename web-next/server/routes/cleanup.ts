// SPDX-License-Identifier: AGPL-3.0-or-later
// 古い投稿のお片づけ。自分の古い投稿を、手元からも相手のサーバからも消す(ピン留めとダイレクトは残す)。
// 常に動くスイッチではなく、「件数を見る → はっきり実行」の二段。数字は、煽りではなく、消える前に正直に見せるため。
//   GET  /settings/cleanup?days=N   N = 0(ぜんぶ)・30・90・365・730。付いていれば、件数を見たあとの頁(確認)
//   GET  /settings/cleanup?done=M   実行を始めたあとの頁(M 件)
//   POST /settings/cleanup/execute  本人確認つきで実行 → 同じ頁へ戻して、件数を見せる
//   POST /settings/cleanup/reauth   本人確認のコードを送る(あいことばを持たない人)
// gateway の口は cookie 専用(ログインと安全・アカウントを閉じると同じ)。本人確認は一か所(reauthField)で出す。
// 「件数を見る」は何も変えない(下見)ので、GET のままにして、頁のアドレスで、確認の段へ戻れるようにしている。

import { gwCookie, type CookieReply } from '../gateway.ts';
import { html, type SafeHtml } from '../html.ts';
import { ok, redirect, route, type Ctx, type Reply } from '../http.ts';
import type { TranslationKey } from '../i18n.ts';
import { layout } from '../views/layout.ts';
import { explain, reauthField, reauthOf, type Auth } from './security.ts';
import { needMe } from './shared.ts';

type Preview = {
  older_than_days: number;
  affected: number;
  protected: { pinned: number; direct: number };
};

// 期間(日)。0 = ぜんぶ。これ以外の数は受けない。
const SPANS: [number, TranslationKey][] = [
  [0, 'cleanup.spanAll'],
  [30, 'cleanup.span30'],
  [90, 'cleanup.span90'],
  [365, 'cleanup.span365'],
  [730, 'cleanup.span730']
];
const DEFAULT_SPAN = 365;

const good = (r: CookieReply<unknown>) => r.status >= 200 && r.status < 300;

// 文字で来た日数を、受けられる数に。受けられなければ null。
function spanOf(raw: string | null | undefined): number | null {
  if (raw == null || !/^\d{1,4}$/.test(raw)) return null;
  const n = Number(raw);
  return SPANS.some(([d]) => d === n) ? n : null;
}

async function cleanupPage(ctx: Ctx, o: { days?: number | null; done?: number; error?: string; status?: number } = {}): Promise<Reply> {
  const t = ctx.t;
  const me = await needMe(ctx);
  const state = await gwCookie<Auth>(ctx, 'GET', '/auth/state');
  const a = state.status === 200 ? (state.body as Auth) : null;
  const flash = ctx.takeFlash();
  const head = html`<header class="timeline page-head"><h1>${t('cleanup.title')}</h1></header>`;
  const back = html`<p class="prose-small"><a class="chip" href="/settings">${t('security.backToSettings')}</a></p>`;
  const wrap = (inner: SafeHtml, status = 200) =>
    ok(layout(ctx, { title: t('cleanup.title'), me, body: html`${head}<div class="timeline stack">${inner}</div>` }), status);

  if (!a || !a.manageable) {
    return wrap(html`<section class="stack"><p>${t('security.needRelogin')}</p><p><a class="chip" href="/login">${t('security.reloginLink')}</a></p></section>${back}`);
  }
  // 入れ替えて使っているとき: cookie の持ち主と、いま見せているアカウントが違うと、別の人の投稿を消してしまう。
  if (a.acct !== me.username) {
    return wrap(html`<section class="stack"><p>${t('security.accountMismatch', { acct: a.acct })}</p><p><a class="chip" href="/login?next=/settings/cleanup">${t('security.reloginLink')}</a></p></section>${back}`);
  }

  const notice = flash ? html`<p class="${flash.kind === 'error' ? 'error' : 'notice'}" role="status">${flash.text}</p>` : '';
  const error = o.error ? html`<p class="error" role="alert">${o.error}</p>` : '';
  const intro = html`<p class="prose-small">${t('cleanup.intro')}</p>`;

  // 実行を始めたあと: 何件を、正直に。
  if (o.done !== undefined) {
    return wrap(html`${notice}<section class="stack">
        ${intro}
        <p>${t('cleanup.startedPre')}${o.done}${t('cleanup.startedPost')}</p>
        <p class="prose-small">${t('cleanup.startedHelp')}</p>
        <p><a class="chip" href="/settings/cleanup">${t('cleanup.again')}</a></p>
      </section>${back}`);
  }

  // 期間を選ぶ(件数を見る前)。
  if (o.days == null) {
    return wrap(html`${notice}<section class="stack">
        ${intro}
        <form class="settings-form" method="get" action="/settings/cleanup">
          <label class="stack-tight">
            <span>${t('cleanup.olderThan')}</span>
            <select name="days">
              ${SPANS.map(([d, key]) => html`<option value="${d}" ${d === DEFAULT_SPAN ? 'selected' : ''}>${t(key)}</option>`)}
            </select>
          </label>
          <div><button type="submit" class="btn">${t('cleanup.preview')}</button></div>
        </form>
        ${error}
      </section>${back}`);
  }

  // 件数を見た(下見)あと。実行は、はっきり押してもらう。
  const pv = await gwCookie<Preview>(ctx, 'POST', '/settings/cleanup/preview', { older_than_days: o.days });
  if (!good(pv)) {
    return wrap(html`<section class="stack">${intro}<p class="error" role="alert">${explain(ctx, pv.body.error, a.has_password)}</p>
        <p><a class="chip" href="/settings/cleanup">${t('security.cancel')}</a></p></section>${back}`, pv.status === 429 ? 429 : 422);
  }
  const p = pv.body as Preview;
  return wrap(
    html`${notice}<section class="stack">
        ${intro}
        <p>${t('cleanup.willPre')}${p.affected}${t('cleanup.willPost')}</p>
        <p class="prose-small">${t('cleanup.keepsPre')}${p.protected.pinned}${t('cleanup.keepsMid')}${p.protected.direct}${t('cleanup.keepsPost')}</p>
        <p class="prose-small">${t('cleanup.confirmHelp')}</p>
        ${p.affected > 0
          ? html`<form class="settings-form" method="post" action="/settings/cleanup/execute">
              <input type="hidden" name="days" value="${o.days}" />
              ${reauthField(ctx, a, 'cleanup', '/settings/cleanup/reauth')}
              <div class="hstack" style="--gap: var(--space-3)">
                <button type="submit" class="btn danger-btn">${t('cleanup.execute')}</button>
                <a class="chip" href="/settings/cleanup">${t('security.cancel')}</a>
              </div>
            </form>`
          : html`<p><a class="chip" href="/settings/cleanup">${t('security.cancel')}</a></p>`}
        ${error}
      </section>${back}`,
    o.status ?? 200
  );
}

route('GET', '/settings/cleanup', (ctx) => {
  const q = ctx.url.searchParams;
  // 実行のあと(PRG)。件数は数字だけ受ける。
  const done = /^\d{1,9}$/.test(q.get('done') ?? '') ? Number(q.get('done')) : undefined;
  return cleanupPage(ctx, { days: spanOf(q.get('days')), done });
});

// 本人確認のコードを送る(あいことばを持たない人)。送ったら、件数を見た頁へ戻る。
route('POST', '/settings/cleanup/reauth', async (ctx) => {
  await needMe(ctx);
  const days = spanOf(String((await ctx.form()).get('days') ?? ''));
  const a = await gwCookie<Auth>(ctx, 'GET', '/auth/state');
  const r = await gwCookie(ctx, 'POST', '/settings/reauth/request', {});
  if (good(r)) ctx.flash('notice', ctx.t('security.codeSent'));
  else ctx.flash('error', explain(ctx, r.body.error, a.status === 200 && !!(a.body as Auth).has_password));
  return redirect(days == null ? '/settings/cleanup' : `/settings/cleanup?days=${days}`);
});

route('POST', '/settings/cleanup/execute', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const days = spanOf(String(f.get('days') ?? ''));
  if (days == null) return redirect('/settings/cleanup');
  const r = await gwCookie<Preview>(ctx, 'POST', '/settings/cleanup/execute', { older_than_days: days, ...reauthOf(f) });
  if (good(r)) return redirect(`/settings/cleanup?done=${(r.body as Preview).affected}`);
  const a = await gwCookie<Auth>(ctx, 'GET', '/auth/state');
  return cleanupPage(ctx, { days, error: explain(ctx, r.body.error, a.status === 200 && !!(a.body as Auth).has_password), status: r.status === 429 ? 429 : 422 });
});
