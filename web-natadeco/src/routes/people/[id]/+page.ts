import { getPerson, personPosts } from '#lib/api.js';
import type { PageLoad } from './$types';

// 人の頁は、誰が見ても同じ(追っているかどうかだけ、ブラウザ側で足す)。
export const load: PageLoad = async ({ params }) => {
  try {
    const [person, rows] = await Promise.all([
      getPerson(params.id),
      personPosts(params.id).catch(() => [])
    ]);
    return { person, rows };
  } catch {
    return { person: null, rows: [] };
  }
};
