// SPDX-License-Identifier: AGPL-3.0-or-later
// リスト。自分で決めた人たちの投稿だけが流れる、小さなタイムライン。
// 一覧(作る・消す)と、リストのタイムラインと、/lists/:id/members(メンバーの出し入れと、ホームへの出し方)。
// 入口は、アバターの菜単。ナビの四つは増やさない。

import { html, raw } from '../html.ts';
import { GatewayError, gwJson, gwPage } from '../gateway.ts';
import { NotFound, ok, redirect, route, type Ctx } from '../http.ts';
import type { Account, Relationship, Status } from '../types.ts';
import { avatar } from '../views/parts.ts';
import { followButton, nameHtml, nameOf } from '../views/account.ts';
import { layout } from '../views/layout.ts';
import { backOr, needMe, statusList } from './shared.ts';

export type List = {
  id: string;
  title: string;
  exclusive?: boolean;
  filter_only_media?: boolean;
  filter_hide_boosts?: boolean;
  filter_hide_sensitive?: boolean;
  filter_keyword?: string;
  filter_replies?: 'all' | 'hide' | 'to_me';
};

const REPLIES = ['all', 'hide', 'to_me'] as const;

const MAX_TITLE = 60;
const idOk = (id: string) => /^[\w-]{1,64}$/.test(id);

async function indexPage(ctx: Ctx, o: { error?: string; title?: string; status?: number } = {}) {
  const t = ctx.t;
  const me = await needMe(ctx);
  const lists = await gwJson<List[]>(ctx, 'GET', '/api/v1/lists').catch(() => null);
  const body = html`<header class="timeline page-head"><h1>${t('lists.title')}</h1></header>
    <section class="timeline stack">
      <form class="form" method="post" action="/lists">
        <div class="hstack hstack-stretch">
          <input class="fill" type="text" name="title" value="${o.title ?? ''}" maxlength="${MAX_TITLE}" required placeholder="${t('lists.newPlaceholder')}" aria-label="${t('lists.newPlaceholder')}" />
          <button type="submit" class="btn">${t('lists.create')}</button>
        </div>
      </form>
      ${o.error ? html`<p class="error" role="alert">${o.error}</p>` : ''}
      ${lists === null ? html`<p class="error">${t('common.readFailed')}</p>` : ''}
      ${lists && lists.length === 0 ? html`<p class="prose-small">${t('lists.empty')}</p>` : ''}
      ${lists && lists.length
        ? html`<div>${lists.map(
            (l) => html`<article class="list-row" id="list-${l.id}">
              <a class="list-link" href="/lists/${l.id}">${l.title}</a>
              <form method="post" action="/lists/${l.id}/delete" up-confirm="${t('lists.confirmDelete', { title: l.title })}">
                <button type="submit" class="chip">${t('lists.delete')}</button>
              </form>
            </article>`
          )}</div>`
        : ''}
    </section>`;
  return ok(layout(ctx, { title: t('lists.title'), me, body }), o.status ?? 200);
}

route('GET', '/lists', (ctx) => indexPage(ctx));

route('POST', '/lists', async (ctx) => {
  await needMe(ctx);
  const title = String((await ctx.form()).get('title') ?? '').trim();
  if (!title || [...title].length > MAX_TITLE) return indexPage(ctx, { title, status: 422 });
  try {
    const l = await gwJson<List>(ctx, 'POST', '/api/v1/lists', { json: { title } });
    if (l && idOk(String(l.id))) return redirect(`/lists/${l.id}`);
    return redirect('/lists');
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    return indexPage(ctx, { title, error: ctx.t('common.deliverFailedRetry'), status: 502 });
  }
});

route('POST', '/lists/:id/delete', async (ctx) => {
  await needMe(ctx);
  const id = ctx.params.id;
  if (idOk(id)) {
    try {
      await gwJson(ctx, 'DELETE', `/api/v1/lists/${encodeURIComponent(id)}`);
    } catch (e) {
      if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
      ctx.flash('error', ctx.t('common.deliverFailedRetry'));
    }
  }
  return redirect('/lists');
});

route('GET', '/lists/:id', async (ctx) => {
  const t = ctx.t;
  const me = await needMe(ctx);
  const id = ctx.params.id;
  const maxId = ctx.url.searchParams.get('max_id') ?? undefined;
  const list = await gwJson<List>(ctx, 'GET', `/api/v1/lists/${encodeURIComponent(id)}`, { notFound: true });

  let items: Status[] = [];
  let next: string | null = null;
  let problem: string | null = null;
  try {
    const page = await gwPage<Status>(ctx, `/api/v1/timelines/list/${encodeURIComponent(id)}`, { query: { limit: '20', max_id: maxId } });
    items = page.items;
    next = page.nextMaxId;
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    problem = e instanceof TypeError ? t('common.reconnecting') : t('common.deliverFailedRetry');
  }
  const moreHref = next ? `/lists/${encodeURIComponent(id)}?max_id=${encodeURIComponent(next)}` : null;
  if (ctx.isUp && ctx.upTarget && ctx.upTarget.includes('li-items:after')) {
    return ok(await statusList(ctx, items, { me, idPrefix: 'li', moreHref }));
  }

  const body = html`<header class="timeline page-head">
      <h1>${list.title || t('listDetail.fallbackTitle')}</h1>
      <p class="prose-small"><a class="chip" href="/lists">${t('listDetail.listIndex')}</a> <a class="chip" href="/lists/${list.id}/members">${t('listDetail.members')}</a></p>
    </header>
    <section class="timeline">
      ${problem ? html`<p class="error">${problem}</p>` : ''}
      ${items.length === 0 && !problem ? html`<p class="prose-small">${t('listDetail.empty')}</p>` : ''}
      ${await statusList(ctx, items, { me, idPrefix: 'li', moreHref })}
    </section>`;
  return ok(layout(ctx, { title: list.title || t('listDetail.fallbackTitle'), me, body }));
});

// ── メンバーと、ホームへの出し方 ─────────────────────────────────
async function membersPage(ctx: Ctx, id: string, o: { error?: string; acct?: string; status?: number } = {}) {
  const t = ctx.t;
  const me = await needMe(ctx);
  const enc = encodeURIComponent(id);
  const [list, members] = await Promise.all([
    gwJson<List>(ctx, 'GET', `/api/v1/lists/${enc}`, { notFound: true }),
    gwJson<Account[]>(ctx, 'GET', `/api/v1/lists/${enc}/accounts`).catch(() => null)
  ]);
  // フォローしていない人は、リストに入れても流れてこない。まとめて一度だけ引いて、その人にだけボタンを添える。
  const ids = (members ?? []).map((a) => a.id);
  const rels = ids.length
    ? await gwJson<Relationship[]>(ctx, 'GET', '/api/v1/accounts/relationships', { query: { 'id[]': ids } }).catch(() => [] as Relationship[])
    : [];
  const relOf = new Map(rels.map((r) => [r.id, r]));
  const unfollowed = (a: Account) => {
    const r = relOf.get(a.id);
    return !!r && !r.following && !r.requested && a.id !== me.id;
  };
  const flash = ctx.takeFlash();
  const checked = (on: boolean | undefined) => (on ? raw('checked') : '');
  const check = (name: string, label: string, on: boolean | undefined) =>
    html`<label class="filter-check"><input type="checkbox" name="${name}" value="1" ${checked(on)} /> <span>${label}</span></label>`;
  const replies = list.filter_replies ?? 'all';
  const title = list.title || t('listDetail.fallbackTitle');

  const body = html`<header class="timeline page-head">
      <h1>${title}</h1>
      <p class="prose-small"><a class="chip" href="/lists/${list.id}">${title}</a></p>
    </header>
    <div class="timeline stack">
      ${flash ? html`<p class="${flash.kind === 'error' ? 'error' : 'notice'}" role="status">${flash.text}</p>` : ''}
      <section class="stack">
        <h2 class="text-base">${t('listDetail.members')}</h2>
        <form class="form" method="post" action="/lists/${list.id}/members">
          <div class="hstack hstack-stretch">
            <input class="fill" type="text" name="acct" value="${o.acct ?? ''}" required placeholder="${t('listDetail.addPlaceholder')}" aria-label="${t('listDetail.addPlaceholder')}" />
            <button type="submit" class="btn">${t('listDetail.add')}</button>
          </div>
        </form>
        ${o.error ? html`<p class="error" role="alert">${o.error}</p>` : ''}
        ${members === null ? html`<p class="error">${t('common.readFailed')}</p>` : ''}
        ${members && members.length === 0 ? html`<p class="prose-small">${t('listDetail.noMembers')}</p>` : ''}
        ${members && members.some(unfollowed) ? html`<p class="prose-small">${t('listDetail.followHint')}</p>` : ''}
        ${members && members.length
          ? html`<div class="account-list">${members.map(
              (a) => html`<article class="account-row" id="lm-${a.id}">
                <a class="account-row-link" href="/@${a.acct}">
                  ${avatar(a.avatar, nameOf(a))}
                  <span class="stack-tight"><span class="display-name">${nameHtml(a)}</span><span class="muted">@${a.acct}</span></span>
                </a>
                ${unfollowed(a) ? followButton(ctx, a.id, relOf.get(a.id)!) : ''}
                <form method="post" action="/lists/${list.id}/members/${a.id}/remove" in-place>
                  <button type="submit" class="chip">${t('listDetail.removeMember')}</button>
                </form>
              </article>`
            )}</div>`
          : ''}
      </section>

      <form class="stack list-gate" method="post" action="/lists/${list.id}/gate">
        <h2 class="text-base">${t('listDetail.homeGateTitle')}</h2>
        <p class="muted text-sm">${t('listDetail.homeGateHint')}</p>
        ${check('exclusive', t('listDetail.gateNever'), list.exclusive)}
        <p class="muted text-sm">${t('listDetail.gateConditionsHint')}</p>
        ${check('filter_only_media', t('timeline.onlyMedia'), list.filter_only_media)}
        ${check('filter_hide_boosts', t('timeline.hideBoosts'), list.filter_hide_boosts)}
        ${check('filter_hide_sensitive', t('timeline.hideSensitive'), list.filter_hide_sensitive)}
        <label class="stack-tight"><span>${t('listDetail.gateKeyword')}</span>
          <input type="text" name="filter_keyword" value="${list.filter_keyword ?? ''}" placeholder="${t('listDetail.gateKeywordPlaceholder')}" />
        </label>
        <label class="stack-tight"><span>${t('listDetail.gateReplies')}</span>
          <select name="filter_replies">
            <option value="all" ${replies === 'all' ? raw('selected') : ''}>${t('listDetail.gateRepliesAll')}</option>
            <option value="hide" ${replies === 'hide' ? raw('selected') : ''}>${t('listDetail.gateRepliesHide')}</option>
            <option value="to_me" ${replies === 'to_me' ? raw('selected') : ''}>${t('listDetail.gateRepliesToMe')}</option>
          </select>
        </label>
        <div><button type="submit" class="btn">${t('settings.save')}</button></div>
      </form>
    </div>`;
  return ok(layout(ctx, { title, me, body }), o.status ?? 200);
}

route('GET', '/lists/:id/members', (ctx) => membersPage(ctx, ctx.params.id));

// 加える: @user / @user@host から人を引いて、リストへ。
route('POST', '/lists/:id/members', async (ctx) => {
  const t = ctx.t;
  await needMe(ctx);
  const id = ctx.params.id;
  const typed = String((await ctx.form()).get('acct') ?? '').trim();
  const acct = typed.replace(/^@/, '');
  if (!acct) return membersPage(ctx, id, { acct: typed, status: 422 });
  let who: Account;
  try {
    who = await gwJson<Account>(ctx, 'GET', '/api/v1/accounts/lookup', { query: { acct }, notFound: true });
  } catch (e) {
    if (e instanceof GatewayError || e instanceof TypeError || e instanceof NotFound) {
      return membersPage(ctx, id, { acct: typed, error: t('listDetail.notFoundPerson'), status: 422 });
    }
    throw e;
  }
  try {
    await gwJson(ctx, 'POST', `/api/v1/lists/${encodeURIComponent(id)}/accounts`, { json: { account_ids: [who.id] } });
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    return membersPage(ctx, id, { acct: typed, error: t('listDetail.addFailed'), status: 422 });
  }
  return redirect(`/lists/${encodeURIComponent(id)}/members`);
});

route('POST', '/lists/:id/members/:account/remove', async (ctx) => {
  await needMe(ctx);
  const { id, account } = ctx.params;
  if (!idOk(account)) return redirect(`/lists/${encodeURIComponent(id)}/members`);
  await gwJson(ctx, 'DELETE', `/api/v1/lists/${encodeURIComponent(id)}/accounts`, { json: { account_ids: [account] } });
  return backOr(ctx, html`<article class="account-row" id="lm-${account}"></article>`);
});

// ホームへの出し方。チェックの無いものは「切」として送る(フォームは、外したチェックを送らないので)。
route('POST', '/lists/:id/gate', async (ctx) => {
  await needMe(ctx);
  const id = ctx.params.id;
  const f = await ctx.form();
  const on = (k: string) => f.get(k) === '1';
  const r = String(f.get('filter_replies') ?? 'all');
  const json = {
    exclusive: on('exclusive'),
    filter_only_media: on('filter_only_media'),
    filter_hide_boosts: on('filter_hide_boosts'),
    filter_hide_sensitive: on('filter_hide_sensitive'),
    filter_keyword: String(f.get('filter_keyword') ?? '').trim().slice(0, 200),
    filter_replies: (REPLIES as readonly string[]).includes(r) ? r : 'all'
  };
  try {
    await gwJson(ctx, 'PUT', `/api/v1/lists/${encodeURIComponent(id)}`, { json });
    ctx.flash('notice', ctx.t('settings.saved'));
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    ctx.flash('error', ctx.t('common.deliverFailedRetry'));
  }
  return redirect(`/lists/${encodeURIComponent(id)}/members`);
});
