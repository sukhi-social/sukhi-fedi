// タグタイムラインの初回取得を load に移す。ForesightJS の予測で
// preloadData が走るので、本文中の #tag リンクへ向かう意図が生まれた時点で
// 一枚を取りにいく。
import { fetchTimeline, type Page, type Status } from '#lib/api.js';

// 動的セグメント (tag) はビルド時のクロールでは見つからないので、この
// ページだけ prerender を切る。adapter-static の fallback (index.html) が
// 返り、クライアントが起動してタグ TL を fetch する。
export const prerender = false;

export async function load({ params }: { params: { tag?: string } }) {
  // 頁がこれまで decodeURIComponent していたのと同じ一回ぶん。SvelteKit が
  // 既に一度解いているので、二度目 ── 挙動を変えないためそのまま残す。
  const tag = decodeURIComponent(params.tag ?? '');
  try {
    const page = await fetchTimeline('tag', { tag });
    return { tag, page, error: null as string | null };
  } catch (e) {
    const msg = e instanceof Error ? e.message : '';
    return { tag, page: { items: [] as Status[], nextMaxId: null } as Page<Status>, error: msg };
  }
}
