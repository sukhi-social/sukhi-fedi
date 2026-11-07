// SPDX-License-Identifier: AGPL-3.0-or-later
// 絵文字の選び口と、@ のあとの名前の候補。どちらも、小さな断片を返すだけ(頁は組まない)。
//   GET /statuses/:id/react   投稿のカードの下に、リアクションの選び口をひらく(?close=1 で、たたむ)
//   GET /people/suggest?q=    書く欄の「@…」の候補(押したときだけ入る)

import { html, type SafeHtml } from '../html.ts';
import { GatewayError, gwJson } from '../gateway.ts';
import { ok, route, type Ctx } from '../http.ts';
import { byCategory, customEmojis } from '../customEmojis.ts';
import type { Account } from '../types.ts';
import { nameOf } from '../views/account.ts';
import { needMe } from './shared.ts';

const domId = (v: string | null, fallback: string) => (v && /^[\w-]{1,80}$/.test(v) ? v : fallback);

async function reactPicker(ctx: Ctx, statusId: string, dom: string): Promise<SafeHtml> {
  const t = ctx.t;
  const groups = byCategory(await customEmojis(ctx));
  return html`<div id="rp-${dom}" class="emoji-picker" role="group" aria-label="${t('emojiPicker.search')}">
    ${groups.length === 0 ? html`<p class="muted text-sm">${t('emojiPicker.none')}</p>` : ''}
    ${groups.map(
      ([cat, list]) => html`<p class="muted text-sm">${cat ?? t('emojiPicker.uncategorized')}</p>
        <div class="emoji-grid">${list.map(
          (e) => html`<form method="post" action="/statuses/${statusId}/react" in-place>
            <input type="hidden" name="emoji" value=":${e.shortcode}:" /><input type="hidden" name="on" value="1" />
            <button type="submit" class="emoji-btn" title=":${e.shortcode}:" aria-label=":${e.shortcode}:"><img class="emoji" src="${e.static_url ?? e.url}" alt="" loading="lazy" /></button>
          </form>`
        )}</div>`
    )}
    <p><a class="chip" href="/statuses/${statusId}/react?close=1&d=${dom}" up-target="#rp-${dom}" up-history="false" up-scroll="false">${t('emojiPicker.close')}</a></p>
  </div>`;
}

route('GET', '/statuses/:id/react', async (ctx) => {
  await needMe(ctx);
  const id = ctx.params.id;
  if (!/^[\w-]{1,64}$/.test(id)) return ok(html``);
  const dom = domId(ctx.url.searchParams.get('d'), `st-${id}`);
  if (ctx.url.searchParams.get('close') === '1') return ok(html`<div id="rp-${dom}"></div>`);
  return ok(await reactPicker(ctx, id, dom));
});

route('GET', '/people/suggest', async (ctx) => {
  await needMe(ctx);
  const q = (ctx.url.searchParams.get('q') ?? '').trim().slice(0, 64);
  if (!q) return ok(html``);
  let people: Account[] = [];
  try {
    people = await gwJson<Account[]>(ctx, 'GET', '/api/v1/accounts/search', { query: { q, limit: '5' } });
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
  }
  if (!Array.isArray(people) || people.length === 0) return ok(html``);
  return ok(html`<ul class="suggest" role="listbox">${people.map(
    (a) => html`<li><button type="button" role="option" data-acct="${a.acct}"><b>${nameOf(a)}</b> <span class="muted">@${a.acct}</span></button></li>`
  )}</ul>`);
});
