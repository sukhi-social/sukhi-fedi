import { error, redirect } from '@sveltejs/kit';
import { getPost } from '$lib/api';
import type { PageLoad } from './$types';

// id しか知らない人のための入り口(通知・友デコ・外に出た古いリンク)。
// 投稿の住所は `/d/<slug>/p/<id>` ── 板の名前を訊いて、そこへ回す。
export const load: PageLoad = async ({ params }) => {
  const post = await getPost(params.id).catch(() => null);
  if (post?.deco_slug) redirect(301, `/d/${post.deco_slug}/p/${post.id}`);
  error(404);
};
