// SPDX-License-Identifier: AGPL-3.0-or-later
// リスト。自分で決めた人たちの投稿だけが流れる、小さなタイムライン。
// ここでは、一覧(作る・消す)と、リストのタイムラインを読むところまで。メンバーの出し入れと、
// ホームへの出し方は /lists/:id/members(次の段)で。
// 入口は、アバターの菜単。ナビの四つは増やさない。

import { html } from '../html.ts';
import { GatewayError, gwJson, gwPage } from '../gateway.ts';
import { ok, redirect, route, type Ctx } from '../http.ts';
import type { Status } from '../types.ts';
import { layout } from '../views/layout.ts';
import { needMe, statusList } from './shared.ts';

export type List = { id: string; title: string };

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
      <p class="prose-small"><a class="chip" href="/lists">${t('listDetail.listIndex')}</a></p>
    </header>
    <section class="timeline">
      ${problem ? html`<p class="error">${problem}</p>` : ''}
      ${items.length === 0 && !problem ? html`<p class="prose-small">${t('listDetail.empty')}</p>` : ''}
      ${await statusList(ctx, items, { me, idPrefix: 'li', moreHref })}
    </section>`;
  return ok(layout(ctx, { title: list.title || t('listDetail.fallbackTitle'), me, body }));
});
