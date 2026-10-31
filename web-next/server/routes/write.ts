// SPDX-License-Identifier: AGPL-3.0-or-later
// 書く・押す頁: 書く(compose)、押す(お気に入り・ブースト・しおり…)、フォロー、通知。
//
// 投稿は、すぐには上がらない。gateway の scheduled_at を使って、約四半刻(POST_DELAY_MIN)あとに
// 上がる ── そのあいだは「お預かり」として、見直せて、とりやめられる。送信ボタンの前の、深呼吸。

import { config } from '../config.ts';
import { gw, gwJson, gwPage, GatewayError } from '../gateway.ts';
import { html, raw, type SafeHtml } from '../html.ts';
import { ok, redirect, route, type Ctx, type Reply } from '../http.ts';
import { saveSession } from '../session.ts';
import { delayWords, timeWords } from '../time.ts';
import type { Account, Notification, NotificationType, Relationship, Status } from '../types.ts';
import { layout } from '../views/layout.ts';
import { avatar } from '../views/parts.ts';
import { followButton, nameHtml, nameOf } from '../views/account.ts';
import { statusCard } from '../views/status.ts';
import { backOr, failText, needMe, replyAcctsFor } from './shared.ts';
import { renderEmojis } from '../emoji.ts';

// ── 押す ────────────────────────────────────────────────────────
const TOGGLES = new Set(['favourite', 'unfavourite', 'reblog', 'unreblog', 'bookmark', 'unbookmark']);

async function cardFor(ctx: Ctx, me: Account, s: Status, note?: string): Promise<SafeHtml> {
  // reblog / unreblog が、包んだ側を返しても、押したのは元の投稿。
  const shown = s.reblog ?? s;
  const replyAccts = await replyAcctsFor(ctx, [shown]);
  return statusCard(ctx, shown, { me, replyAccts, note });
}

route('POST', '/statuses/:id/:verb', async (ctx) => {
  const me = await needMe(ctx);
  const id = encodeURIComponent(ctx.params.id);
  const verb = ctx.params.verb;

  if (TOGGLES.has(verb)) {
    const s = await gwJson<Status>(ctx, 'POST', `/api/v1/statuses/${id}/${verb}`, { json: {} });
    return backOr(ctx, await cardFor(ctx, me, s));
  }
  if (verb === 'delete') {
    await gw(ctx, 'DELETE', `/api/v1/statuses/${id}`);
    // 消えたところには、空の印だけが残る(Unpoly が差し替える先)。
    return backOr(ctx, html`<div id="st-${ctx.params.id}"></div>`);
  }
  if (verb === 'report') {
    const f = await ctx.form();
    await gw(ctx, 'POST', '/api/v1/reports', { json: { account_id: String(f.get('account_id') ?? ''), status_ids: [ctx.params.id] } });
    const s = await gwJson<Status>(ctx, 'GET', `/api/v1/statuses/${id}`, { auth: 'optional' });
    return backOr(ctx, await cardFor(ctx, me, s, ctx.t('status.reported')));
  }
  if (verb === 'react') {
    const f = await ctx.form();
    const emoji = encodeURIComponent(String(f.get('emoji') ?? ''));
    const s = await gwJson<Status>(ctx, f.get('on') === '1' ? 'PUT' : 'DELETE', `/api/v1/sukhi/statuses/${id}/react/${emoji}`);
    return backOr(ctx, await cardFor(ctx, me, s));
  }
  return redirect('/');
});

route('POST', '/accounts/:id/:verb', async (ctx) => {
  await needMe(ctx);
  const verb = ctx.params.verb;
  if (verb !== 'follow' && verb !== 'unfollow') return redirect('/');
  const rel = await gwJson<Relationship>(ctx, 'POST', `/api/v1/accounts/${encodeURIComponent(ctx.params.id)}/${verb}`, { json: {} });
  return backOr(ctx, followButton(ctx, ctx.params.id, rel));
});

// ── 書く(compose) ──────────────────────────────────────────────
type Scheduled = { id: string; scheduled_at: string; params?: { text?: string } };
type Held = { id: string; text: string; at: string };

type ComposeView = {
  values?: { status?: string; spoiler?: string; sensitive?: boolean; visibility?: string };
  replyId?: string;
  quoteId?: string;
  error?: string;
};

// お預かりの一覧。gateway が一覧の口を持っていればそれを、無ければ手元のひかえ(未来のものだけ)を。
async function heldList(ctx: Ctx): Promise<Held[]> {
  try {
    const list = await gwJson<Scheduled[]>(ctx, 'GET', '/api/v1/scheduled_statuses');
    if (Array.isArray(list)) return list.map((s) => ({ id: s.id, text: s.params?.text ?? '', at: s.scheduled_at }));
  } catch {
    // 一覧の口が無い(または落ちている)。手元のひかえへ。
  }
  const now = Date.now();
  return (ctx.session?.pending ?? []).filter((p) => Date.parse(p.at) > now);
}

async function composePage(ctx: Ctx, me: Account, v: ComposeView = {}, status = 200): Promise<Reply> {
  const t = ctx.t;
  const q = ctx.url.searchParams;
  const replyId = v.replyId ?? q.get('reply_to') ?? undefined;
  const quoteId = v.quoteId ?? q.get('quote') ?? undefined;

  const fetchOne = (id?: string) =>
    id ? gwJson<Status>(ctx, 'GET', `/api/v1/statuses/${encodeURIComponent(id)}`, { auth: 'optional' }).catch(() => null) : Promise.resolve(null);
  const [replyTo, quoteOf, held] = await Promise.all([fetchOne(replyId), fetchOne(quoteId), heldList(ctx)]);

  // 返信は、相手の @ を頭に置いて始める(自分への返信は、置かない)。
  // 他のアプリの「共有」から来たとき(manifest の share_target)は、題・本文・URL を、重ならないように置く。
  const shared = [...new Set(['title', 'text', 'url'].map((k) => (q.get(k) ?? '').trim()).filter(Boolean))].join('\n');
  const text = v.values?.status ?? (replyTo && replyTo.account.acct !== me.acct ? `@${replyTo.account.acct} ` : shared);
  const vis = v.values?.visibility ?? 'public';
  const visLabels: [string, string][] = [
    ['public', t('compose.visPublic')],
    ['unlisted', t('compose.visUnlisted')],
    ['private', t('compose.visPrivate')],
    ['direct', t('compose.visDirect')]
  ];
  const when = delayWords(config.postDelayMin, ctx.locale);

  const body = html`<header class="timeline page-head"><h1>${t('nav.compose')}</h1></header>
    <div class="timeline stack">
      <form class="composer composer-page" method="post" action="/compose" enctype="multipart/form-data" x-data="{ cw: ${String(!!v.values?.spoiler)}, files: [] }">
        ${replyId ? html`<input type="hidden" name="in_reply_to_id" value="${replyId}" />` : ''}
        ${quoteId ? html`<input type="hidden" name="quote_id" value="${quoteId}" />` : ''}
        ${quoteOf
          ? html`<p class="composer-reply"><span>${t('compose.quoting', { acct: quoteOf.account.acct })}</span><a class="chip" href="/compose">${t('compose.cancel')}</a></p>
              <div class="quote-card"><div class="quote-head">${avatar(quoteOf.account.avatar, nameOf(quoteOf.account), 'quote-avatar')}<span class="quote-name">${nameHtml(quoteOf.account)}</span><span class="quote-acct">@${quoteOf.account.acct}</span></div>
              <div class="quote-content">${raw(renderEmojis(quoteOf.content, quoteOf.emojis))}</div></div>`
          : replyTo
            ? html`<p class="composer-reply"><span>${t('compose.replyTo', { acct: replyTo.account.acct })}</span><a class="chip" href="/compose">${t('compose.cancel')}</a></p>`
            : ''}
        ${v.error ? html`<p class="error" role="alert">${v.error}</p>` : ''}

        <label class="stack-tight" x-show="cw" x-cloak>
          <span>${t('compose.spoilerLabel')}</span>
          <input type="text" name="spoiler_text" value="${v.values?.spoiler ?? ''}" placeholder="${t('compose.spoilerPlaceholder')}" maxlength="80" />
        </label>

        <label class="stack-tight">
          <span class="visually-hidden">${t('compose.bodyLabel')}</span>
          <textarea name="status" class="grows" rows="6" required autofocus placeholder="${replyTo ? t('compose.placeholderReply') : t('compose.placeholderNew')}">${text}</textarea>
        </label>

        <details class="composer-more">
          <summary>${t('compose.more')}</summary>
          <div class="composer-more-row">
            <label class="stack-tight"><input type="checkbox" x-model="cw" /><span>${t('compose.fold')}</span></label>
            <label class="stack-tight"><input type="checkbox" name="sensitive" value="1" ${v.values?.sensitive ? raw('checked') : ''} /><span>${t('compose.sensitive')}</span></label>
          </div>
        </details>

        <div class="composer-row">
          <label class="chip">${t('compose.addImage')}
            <input type="file" name="files" accept="image/*,video/*,audio/*" multiple hidden @change="files = [...$event.target.files].map((f) => f.name)" />
          </label>
          <label class="stack-tight">
            <span class="visually-hidden">${t('compose.visLabel')}</span>
            <select name="visibility">${visLabels.map(([val, label]) => html`<option value="${val}" ${val === vis ? raw('selected') : ''}>${label}</option>`)}</select>
          </label>
          <button type="submit" class="btn primary px-6 py-2">${t('compose.submit')}</button>
        </div>
        <ul class="composer-files" x-show="files.length" x-cloak><template x-for="name in files"><li class="muted" x-text="name"></li></template></ul>
        <p class="composer-hint">${config.postDelayMin > 0 ? t('compose.queuedHint', { when }) : ''}</p>
      </form>

      ${held.length
        ? html`<section class="held" aria-label="${t('compose.holding')}">
            <h2 class="muted">${t('compose.holding')}</h2>
            ${held.map(
              (h) => html`<article class="held-item">
                <p class="held-text">${h.text}</p>
                <p class="muted">${t('compose.holdingUntil', { when: timeWords(h.at, ctx.locale) })}</p>
                <form method="post" action="/compose/withdraw">
                  <input type="hidden" name="id" value="${h.id}" />
                  <button type="submit" class="chip">${t('compose.withdraw')}</button>
                </form>
              </article>`
            )}
          </section>`
        : ''}
    </div>`;
  return ok(layout(ctx, { title: t('nav.compose'), me, body }), status);
}

route('GET', '/compose', async (ctx) => composePage(ctx, await needMe(ctx)));

route('POST', '/compose', async (ctx) => {
  const t = ctx.t;
  const me = await needMe(ctx);
  const f = await ctx.form();
  const str = (k: string) => String(f.get(k) ?? '');
  const text = str('status').trim();
  const values = { status: str('status'), spoiler: str('spoiler_text'), sensitive: f.get('sensitive') === '1', visibility: str('visibility') || 'public' };
  const view = (error: string): Promise<Reply> => composePage(ctx, me, { values, replyId: str('in_reply_to_id') || undefined, quoteId: str('quote_id') || undefined, error }, 422);

  if (!text) return view(t('feedback.empty'));

  try {
    // 画像は、先に gateway へ(四枚まで)。
    const mediaIds: string[] = [];
    const files = f.getAll('files').filter((x): x is File => x instanceof File && x.size > 0).slice(0, 4);
    for (const file of files) {
      const fd = new FormData();
      fd.set('file', file);
      const m = await gwJson<{ id: string }>(ctx, 'POST', '/api/v1/media', { form: fd });
      mediaIds.push(m.id);
    }

    const body: Record<string, unknown> = { status: text, visibility: values.visibility };
    if (values.spoiler) body.spoiler_text = values.spoiler;
    if (values.sensitive || values.spoiler) body.sensitive = true;
    if (str('in_reply_to_id')) body.in_reply_to_id = str('in_reply_to_id');
    if (str('quote_id')) body.quote_id = str('quote_id');
    if (mediaIds.length) body.media_ids = mediaIds;
    // 四半刻の余白。0 にすれば、すぐ上がる。
    const delayed = config.postDelayMin > 0;
    if (delayed) body.scheduled_at = new Date(Date.now() + config.postDelayMin * 60_000).toISOString();

    const res = await gwJson<Status | Scheduled>(ctx, 'POST', '/api/v1/statuses', { json: body });

    if (delayed && res && 'scheduled_at' in res) {
      // gateway が一覧の口を持たないときのために、手元にもひかえておく。
      const s = ctx.sess();
      s.pending = [...(s.pending ?? []).filter((p) => Date.parse(p.at) > Date.now()), { id: res.id, text, at: res.scheduled_at }];
      saveSession(s);
      ctx.flash('notice', t('compose.queued', { when: delayWords(config.postDelayMin, ctx.locale) }));
      return redirect('/compose');
    }
    ctx.flash('notice', t('compose.posted'));
    return redirect('/');
  } catch (e) {
    if (e instanceof GatewayError || e instanceof TypeError) return view(failText(ctx, e));
    throw e;
  }
});

route('POST', '/compose/withdraw', async (ctx) => {
  await needMe(ctx);
  const f = await ctx.form();
  const id = String(f.get('id') ?? '');
  try {
    await gw(ctx, 'DELETE', `/api/v1/scheduled_statuses/${encodeURIComponent(id)}`);
    const s = ctx.sess();
    s.pending = (s.pending ?? []).filter((p) => p.id !== id);
    saveSession(s);
    ctx.flash('notice', ctx.t('compose.withdrawn'));
  } catch (e) {
    if (!(e instanceof GatewayError)) throw e;
    ctx.flash('error', ctx.t('compose.withdrawFailed'));
  }
  return redirect('/compose');
});

// ── 通知 ────────────────────────────────────────────────────────
// 二つの層(lib/notify.ts と同じ割り方)。
//   あなたへ  返信・フォロー申請。会話で、相手が待っている。だからすぐ出す。
//   反応      お気に入り・ブースト・フォローなど。うれしいけれど、急がない。
//             だから NOTIFY_HOLD_MIN(既定 一刻)ほど置いてから、ポツポツ出す。
//             置くのも、同じ投稿への反応を一つにまとめるのも、gateway がやる(アカウントごとの
//             設定と、同じ規則。docs/MASTODON_API.md の「Pace」)。ここは、設定にかかわらず
//             いつも hold_minutes と grouping を添えて、より遅く・まとめる側に寄せるだけ。
// 未読の数も、点も、出さない。「新しい通知は、ここまで」の境い目も、引く必要がない。
const DIRECT: NotificationType[] = ['mention', 'follow_request'];

// 通知を読む・片づける呼び出しには、いつもこれを添える。gateway は、アカウントの設定より
// 遅く・まとめる側にだけ、これを効かせる。
const pace = (): Record<string, string> => ({
  hold_minutes: String(config.notifyHoldMin),
  grouping: 'true'
});

route('GET', '/notifications', async (ctx) => {
  const t = ctx.t;
  const me = await needMe(ctx);
  const q = ctx.url.searchParams;
  const tier = q.get('tier') === 'ambient' ? 'ambient' : 'direct';
  const maxId = q.get('max_id') ?? undefined;

  const query: Record<string, string | string[] | undefined> = { limit: '30', max_id: maxId, ...pace() };
  if (tier === 'direct') query['types[]'] = DIRECT;
  else query['exclude_types[]'] = DIRECT;

  const page = await gwPage<Notification>(ctx, '/api/v1/notifications', { query });

  // 置く時間が過ぎたものだけが、gateway から来る。道の途中のものがあるかは、こちらからは見えない。
  const arrived = page.items;

  const summary = (n: Notification): string => {
    switch (n.type) {
      case 'favourite': return t('notif.favourited');
      case 'reblog': return t('notif.reblogged');
      case 'follow': return t('notif.followed');
      case 'follow_request': return t('notif.followRequest');
      case 'mention': return t('notif.mentioned');
      case 'status': return t('notif.posted');
      case 'poll': return t('notif.pollEnded');
      case 'update': return t('notif.updated');
      case 'reaction': return t('notif.reacted');
      default: return t('notif.generic');
    }
  };

  // まとめた行は、名前だけを並べる(数は言わない)。三人まで、あとは「ほか」。
  const NAMED = 3;
  const who = (n: Notification) => {
    const rest = (n.group?.accounts ?? []).slice(1);
    if (rest.length === 0) return '';
    return html`${rest.slice(0, NAMED - 1).map(
      (a) => html`<span class="notif-also">、<a href="/@${a.acct}">${nameHtml(a)}</a></span>`
    )}${rest.length > NAMED - 1 ? html`<span class="notif-also">${t('notif.groupOthers')}</span>` : ''}`;
  };

  const replyAccts = await replyAcctsFor(ctx, arrived.flatMap((n) => (n.status ? [n.status] : [])));
  const moreHref = page.nextMaxId ? `/notifications?tier=${tier}&max_id=${encodeURIComponent(page.nextMaxId)}` : null;
  const tabLink = (k: string, label: string) => html`<a class="tab" href="/notifications?tier=${k}" aria-current="${tier === k ? 'true' : null}">${label}</a>`;

  const body = html`<header class="timeline page-head">
      <h1>${t('notif.title')}</h1>
      ${arrived.length
        ? html`<span class="page-nav"><form method="post" action="/notifications/clear" up-confirm="${t('notif.confirmClear')}"><button class="chip" type="submit">${t('notif.clearAll')}</button></form></span>`
        : ''}
    </header>
    <nav class="tabs timeline" aria-label="${t('notif.tabsLabel')}">${tabLink('direct', t('notif.tabToYou'))}${tabLink('ambient', t('notif.tabReactions'))}</nav>
    <section class="timeline" id="nf-section">
      ${tier === 'ambient' ? html`<p class="prose-small">${t('notif.holdNote')}</p>` : ''}
      ${arrived.length === 0 ? html`<p class="prose-small">${tier === 'direct' ? t('notif.emptyToYou') : t('notif.emptyReactions')}</p>` : ''}
      <div id="nf-items">
        ${arrived.map(
          (n) => html`<article class="notif" id="nf-${n.id}">
            <header class="notif-head">
              <a class="notif-who" href="/@${n.account.acct}">${avatar(n.account.avatar, nameOf(n.account), 'avatar avatar-sm')}<span class="display-name">${nameHtml(n.account)}</span></a>${who(n)}
              <span class="notif-summary">${summary(n)}</span>
              <form class="notif-dismiss" method="post" action="/notifications/${n.id}/dismiss" in-place>
                <button type="submit" class="chip" aria-label="${t('notif.dismiss')}">×</button>
              </form>
            </header>
            ${n.status ? statusCard(ctx, n.status, { me, replyAccts }) : ''}
          </article>`
        )}
      </div>
      <div id="nf-more">${moreHref
        ? html`<a class="load-more" href="${moreHref}" up-target="#nf-items:after, #nf-more" up-history="false" up-scroll="false">${t('common.loadMore')}</a>`
        : arrived.length ? html`<p class="the-end" role="note">${t('end.here')}</p>` : ''}</div>
    </section>`;

  // 「もっと読む」で続きの断片だけを要求されたときは、外側の枠を省いて返す。
  if (ctx.isUp && ctx.upTarget && ctx.upTarget.includes('nf-items:after')) {
    return ok(html`
      <div id="nf-items">
        ${arrived.map(
          (n) => html`<article class="notif" id="nf-${n.id}">
            <header class="notif-head">
              <a class="notif-who" href="/@${n.account.acct}">${avatar(n.account.avatar, nameOf(n.account), 'avatar avatar-sm')}<span class="display-name">${nameHtml(n.account)}</span></a>${who(n)}
              <span class="notif-summary">${summary(n)}</span>
              <form class="notif-dismiss" method="post" action="/notifications/${n.id}/dismiss" in-place>
                <button type="submit" class="chip" aria-label="${t('notif.dismiss')}">×</button>
              </form>
            </header>
            ${n.status ? statusCard(ctx, n.status, { me, replyAccts }) : ''}
          </article>`
        )}
      </div>
      <div id="nf-more">${moreHref
        ? html`<a class="load-more" href="${moreHref}" up-target="#nf-items:after, #nf-more" up-history="false" up-scroll="false">${t('common.loadMore')}</a>`
        : arrived.length ? html`<p class="the-end" role="note">${t('end.here')}</p>` : ''}</div>
    `);
  }

  return ok(layout(ctx, { title: t('notif.title'), me, body }));
});

route('POST', '/notifications/clear', async (ctx) => {
  await needMe(ctx);
  await gw(ctx, 'POST', '/api/v1/notifications/clear', { json: {}, query: pace() });
  return redirect('/notifications');
});

route('POST', '/notifications/:id/dismiss', async (ctx) => {
  await needMe(ctx);
  await gw(ctx, 'POST', `/api/v1/notifications/${encodeURIComponent(ctx.params.id)}/dismiss`, { json: {}, query: pace() });
  return backOr(ctx, html`<div class="notif notif-dismissed" id="nf-${ctx.params.id}"></div>`);
});

