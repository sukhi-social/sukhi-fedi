// SPDX-License-Identifier: AGPL-3.0-or-later
// 管理者の「おしらせ」。ホームの先頭に、まだ読んでいない新しい一枚だけを、そっと置く。
// 「わかりました」を押すと、サーバがそれを覚える(別の端末でも出てこない)。溜まっていても、急かさない ──
// 一度に出すのは一枚で、閉じたら、次に頁を開いたときに次の一枚。
//
// 中身は管理者が書いた HTML。ここでは文字だけにして出す(タグは通さない)。

import { html, type SafeHtml } from '../html.ts';
import { gwJson } from '../gateway.ts';
import { route, type Ctx } from '../http.ts';
import { plainText } from '../maintenance.ts';
import { backOr, needMe } from './shared.ts';

type Announcement = { id: string; content: string; read: boolean; published_at: string | null };

const idOk = (id: string) => /^[\w-]{1,64}$/.test(id);

function paragraphs(text: string): SafeHtml {
  return html`${text.split('\n\n').map((p) => html`<p>${p.split('\n').flatMap((l, i) => (i ? [html`<br />`, l] : [l]))}</p>`)}`;
}

/** まだ読んでいない、いちばん新しい一枚。読めなかったり、無かったりしたら、何も出さない。 */
export async function announcementCard(ctx: Ctx): Promise<SafeHtml | ''> {
  let all: Announcement[];
  try {
    all = await gwJson<Announcement[]>(ctx, 'GET', '/api/v1/announcements');
  } catch {
    return '';
  }
  if (!Array.isArray(all)) return '';
  const next = all
    .filter((a) => !a.read && idOk(String(a.id)))
    .sort((a, b) => String(b.published_at ?? '').localeCompare(String(a.published_at ?? '')))[0];
  if (!next) return '';
  const text = plainText(next.content ?? '');
  if (!text) return '';
  const t = ctx.t;
  return html`<aside class="announce" id="an-${next.id}" data-in-place aria-label="${t('announce.label')}">
    ${paragraphs(text)}
    <form method="post" action="/announcements/${next.id}/dismiss" in-place>
      <button type="submit" class="chip">${t('announce.dismiss')}</button>
    </form>
  </aside>`;
}

route('POST', '/announcements/:id/dismiss', async (ctx) => {
  await needMe(ctx);
  const id = ctx.params.id;
  if (!idOk(id)) return backOr(ctx, null);
  await gwJson(ctx, 'POST', `/api/v1/announcements/${encodeURIComponent(id)}/dismiss`, { json: {} }).catch(() => {});
  // 届かなくても、いまは静かに閉じる(次に開いたとき、また出る)。
  return backOr(ctx, html`<div id="an-${id}"></div>`);
});
