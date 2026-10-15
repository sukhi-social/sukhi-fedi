import { browser } from '$app/env';
import { getDeco, listPosts, listFlow, listDecoTags, startOfToday } from '#lib/api.js';
import type { PageLoad } from './$types';

// 板一枚と、その中身。サーバでは匿名で取るので、入っている人はブラウザ
// 側で取り直す(`anonymous`)。話す板の「今日」は読む人の時計で切るもので、
// サーバはそれを知らない ── サーバでは since 無しで最近の分を描き、
// ブラウザが自分の真夜中で取り直す。
export const load: PageLoad = async ({ params, url }) => {
  const slug = params.slug;
  const tag = url.searchParams.get('tag');
  const anonymous = !browser;

  try {
    const deco = await getDeco(slug);
    const posts =
      deco.kind === 'talk'
        ? await listFlow(slug, { since: browser ? startOfToday() : undefined, tag })
        : await listPosts(slug, undefined, tag);
    const tags = await listDecoTags(slug).catch(() => []);
    return { deco, posts, tags, anonymous };
  } catch {
    return { deco: null, posts: [], tags: [], anonymous };
  }
};
