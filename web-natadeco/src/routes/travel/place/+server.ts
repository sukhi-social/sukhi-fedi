import { json } from '@sveltejs/kit';
import { resolvePlace } from '$lib/server/place';
import type { RequestHandler } from './$types';

// 場所のリンクを、名前と座標にする口。ブラウザは他所の地図サイトに
// 直接は訊けない(CORS)ので、同じ origin のここが代わりに読む。
// 見つからなければ 404 ── 書く人は場所なしで置くか、書き直す。
export const GET: RequestHandler = async ({ url }) => {
  const q = url.searchParams.get('url') ?? '';
  if (!q.trim() || q.length > 2000) return json({ error: 'no link' }, { status: 400 });

  const place = await resolvePlace(q, AbortSignal.timeout(8000)).catch(() => null);
  if (!place) return json({ error: 'not found' }, { status: 404 });
  return json(place);
};
