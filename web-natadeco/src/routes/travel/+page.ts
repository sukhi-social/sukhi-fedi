import { browser } from '$app/env';
import { listFlow, listDecoTags, getDeco } from '#lib/api.js';
import { TRAVEL_SLUG } from '#lib/site.js';
import type { PageLoad } from './$types';

// 旅の玄関。記録は話す板の流れ(新しい順)から、返事を除いたもの。
// サーバでは匿名で描き、入っている人はブラウザで反応の me を取り直す。
export const load: PageLoad = async ({ url }) => {
  const tag = url.searchParams.get('tag');
  const anonymous = !browser;
  try {
    const [deco, rows, tags] = await Promise.all([
      getDeco(TRAVEL_SLUG),
      listFlow(TRAVEL_SLUG, { tag }),
      listDecoTags(TRAVEL_SLUG).catch(() => [])
    ]);
    return { deco, rows, tags, anonymous };
  } catch {
    return { deco: null, rows: [], tags: [], anonymous };
  }
};
