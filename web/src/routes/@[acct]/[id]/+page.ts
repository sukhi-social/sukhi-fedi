// スレッドの初回取得を load に移す。ForesightJS の予測で preloadData が
// 走るので、投稿のリンクへ向かう意図が生まれた時点で本体と文脈を取りに
// いく ── クリックしたときには揃っている。
//
// 期待どおり失敗は throw せず種別を返す(load は予測でも走るので、ここで
// ログアウト等の副作用を起こさない)。
import { getStatus, getContext, type Status } from '#lib/api.js';

export async function load({ params }: { params: { id?: string } }) {
  const id = params.id ?? '';
  try {
    // スレッドの前後を一緒に出したいので、本体と文脈を並べて取る。
    const status = await getStatus(id);
    const ctx = await getContext(id);
    return {
      id,
      status,
      ancestors: ctx.ancestors,
      descendants: ctx.descendants,
      error: null as string | null
    };
  } catch (e) {
    const msg = e instanceof Error ? e.message : '';
    return { id, status: null, ancestors: [] as Status[], descendants: [] as Status[], error: msg };
  }
}
