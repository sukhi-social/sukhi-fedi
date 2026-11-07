// SPDX-License-Identifier: AGPL-3.0-or-later
// しおりと、お気に入り。自分だけが見る、ふたつの棚(相手には、数も、誰が挟んだかも、届かない)。
// 入口は、アバターの菜単。棚は二つの道(/bookmarks と /favourites)で、上の二つのタブで行き来する ──
// 一頁・二タブの形。外したくなったら、カードの印を押しなおすだけ(その場で戻せるよう、列からは消さない)。

import { html } from '../html.ts';
import { GatewayError, gwPage } from '../gateway.ts';
import { ok, route, type Ctx } from '../http.ts';
import type { Status } from '../types.ts';
import { layout } from '../views/layout.ts';
import { needMe, statusList } from './shared.ts';

type Shelf = 'bookmarks' | 'favourites';

async function shelf(ctx: Ctx, kind: Shelf) {
  const t = ctx.t;
  const me = await needMe(ctx);
  const maxId = ctx.url.searchParams.get('max_id') ?? undefined;
  const title = t(kind === 'bookmarks' ? 'bookmarks.title' : 'favourites.title');

  let items: Status[] = [];
  let next: string | null = null;
  let problem: string | null = null;
  try {
    const page = await gwPage<Status>(ctx, `/api/v1/${kind}`, { query: { limit: '20', max_id: maxId }, auth: true });
    items = page.items;
    next = page.nextMaxId;
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
    problem = e instanceof TypeError ? t('common.reconnecting') : t('common.deliverFailedRetry');
  }

  const prefix = kind === 'bookmarks' ? 'bm' : 'fav';
  const moreHref = next ? `/${kind}?max_id=${encodeURIComponent(next)}` : null;

  // 「もっと読む」で続きだけを求められたときは、枠を省く。
  if (ctx.isUp && ctx.upTarget && ctx.upTarget.includes(`${prefix}-items:after`)) {
    return ok(await statusList(ctx, items, { me, idPrefix: prefix, moreHref }));
  }

  const tab = (k: Shelf, label: string) => html`<a class="tab" href="/${k}" aria-current="${kind === k ? 'true' : null}">${label}</a>`;
  const body = html`<h1 class="visually-hidden">${title}</h1>
    <nav class="tabs timeline" aria-label="${t('bookmarks.title')} / ${t('favourites.title')}">
      ${tab('bookmarks', t('bookmarks.title'))}${tab('favourites', t('favourites.title'))}
    </nav>
    <section class="timeline">
      ${problem ? html`<p class="error">${problem}</p>` : ''}
      ${items.length === 0 && !problem ? html`<p class="prose-small">${t(kind === 'bookmarks' ? 'bookmarks.empty' : 'favourites.empty')}</p>` : ''}
      ${await statusList(ctx, items, { me, idPrefix: prefix, moreHref })}
    </section>`;
  return ok(layout(ctx, { title, me, body }));
}

route('GET', '/bookmarks', (ctx) => shelf(ctx, 'bookmarks'));
route('GET', '/favourites', (ctx) => shelf(ctx, 'favourites'));
