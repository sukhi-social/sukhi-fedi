// 記事の初回取得を load に移す。ForesightJS の予測で preloadData が走る
// ので、記事のリンクへ向かう意図が生まれた時点で本体と返信を取りにいく。
//
// 期待どおり失敗は throw せず種別を返す(load は予測でも走るので、ここで
// ログアウト等の副作用を起こさない)。
import { getStatus, getContext, type Status } from '#lib/api.js';

// 動的セグメント (id) はビルド時のクロールでは見つからないので、この
// ルートだけ prerender を切る。中身は SPA 側で fetch するため ssr も切る。
// プロフィール (@[acct]) と同じ扱い。adapter-static の fallback が起動する。
export const prerender = false;
export const ssr = false;

export async function load({ params }: { params: { id?: string } }) {
  const id = params.id ?? '';
  try {
    const status = await getStatus(id);
    const ctx = await getContext(id);
    return { id, status, descendants: ctx.descendants, error: null as string | null };
  } catch (e) {
    const msg = e instanceof Error ? e.message : '';
    return { id, status: null, descendants: [] as Status[], error: msg };
  }
}
