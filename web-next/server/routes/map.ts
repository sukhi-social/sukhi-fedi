// SPDX-License-Identifier: AGPL-3.0-or-later
// この星の路線図。入っていない人にも開いている(gateway の GET /api/map が、そう開いている)。
//
//   GET /map        頁。数字(はかれたとき)つきで、まるごと描く。
//   GET /map/live   30 秒ごとの取りなおし用。領域(rail / board / universe)だけを返す(絵の差しかえは public/js/app.js)。
//
// 数字は、gateway が 5 秒だけ覚えている(キャッシュは、そこ一か所)。ここでは覚えない。
// はかれなかったとき: 頁は「はかっています…」と、線路だけを描く。/map/live は 502 ── ブラウザは、いまある絵のまま、一言そえる。

import { html } from '../html.ts';
import { gwJson, GatewayError } from '../gateway.ts';
import { empty, ok, route, type Ctx } from '../http.ts';
import { layout } from '../views/layout.ts';
import { boardRegion, drawing, parseSample, railRegion, universeRegion, type MapSample } from '../views/map.ts';
import { maybeMe } from './shared.ts';

// はかれなければ null(gateway に届かない・読めない返事)。裏の取りなおしは「後ろに回してよい」と名乗る。
async function measure(ctx: Ctx, background: boolean): Promise<MapSample | null> {
  try {
    return parseSample(await gwJson<unknown>(ctx, 'GET', '/api/map', { auth: false, background }));
  } catch (e) {
    if (!(e instanceof GatewayError || e instanceof TypeError || e instanceof SyntaxError)) throw e;
    return null;
  }
}

route('GET', '/map', async (ctx) => {
  const t = ctx.t;
  const [me, sample] = await Promise.all([maybeMe(ctx), measure(ctx, false)]);
  const body = html`<section class="hero">
      <h1>${t('map.title')}</h1>
      <p class="tagline">${t('map.tagline')}</p>
    </section>
    <div class="map-page" data-map-live="/map/live">
      <section class="section map-scroll">${drawing(t, railRegion(sample))}</section>

      <section class="section measure">
        <h2>${t('map.boardTitle')}</h2>
        <p class="map-error" data-map-error${sample ? ' hidden' : ''}>${t('map.boardError')}</p>
        ${boardRegion(t, ctx.locale, ctx.tz, sample)}
      </section>

      ${universeRegion(t, sample)}

      <section class="section measure">
        <h2>${t('map.aboutTitle')}</h2>
        <p class="prose-small">${t('map.aboutFront')}</p>
        <p class="prose-small">${t('map.aboutFed')}</p>
        <p class="prose-small">${t('map.aboutWt')}</p>
        <p class="prose-small">${t('map.aboutEvents')}</p>
        <p class="prose-small map-note">${t('map.aboutNumbers')}</p>
      </section>
    </div>`;
  return ok(layout(ctx, { title: t('map.title'), me, entrance: !me, legal: !me, body }));
});

route('GET', '/map/live', async (ctx) => {
  const t = ctx.t;
  const sample = await measure(ctx, true);
  if (!sample) return empty(502);
  // rail は <g>(SVG の中の仲間)── HTML の読みかたでは外れてしまうので、<svg> に包んで返す。
  return ok(html`<svg>${railRegion(sample)}</svg>${boardRegion(t, ctx.locale, ctx.tz, sample)}${universeRegion(t, sample)}`, 200, {
    'cache-control': 'no-store'
  });
});
