// プロフィールの初回取得を load に移す。
//
// ForesightJS の予測で `preloadData` が走るので、プロフィールのリンクへ
// 向かう意図が生まれた時点で、アカウント・自分の関係・投稿・記事・ピンが
// 取れ始める。クリックしたときには読み込み中の無い遷移になる。
//
// 期待どおり失敗するもの(未ログイン・見つからない)は throw せず、種別を
// 返して頁に委ねる ── load は予測でも走るので、ここで副作用(ログアウト等)を
// 起こさない。頁が onMount で拾う。
import { browser } from '$app/env';
import {
  lookupAccount,
  getAccountStatuses,
  getRelationships,
  verifyCredentials,
  type Account,
  type Page,
  type Relationship,
  type Status
} from '#lib/api.js';
import { isLoggedIn } from '#lib/auth.js';

const emptyPage: Page<Status> = { items: [], nextMaxId: null };

export async function load({ params }: { params: { acct?: string } }) {
  const acct = params.acct ?? '';
  try {
    const account = await lookupAccount(acct);

    // 自分かどうかを判定するため、ログイン時だけ自分を引く。
    let me: Account | null = null;
    let rel: Relationship | null = null;
    if (browser && isLoggedIn()) {
      try {
        me = await verifyCredentials();
      } catch {
        me = null;
      }
      if (me && me.id !== account.id) {
        const rs = await getRelationships([account.id]).catch(() => [] as Relationship[]);
        rel = rs[0] ?? null;
      }
    }

    // 投稿・記事・ピン留めを一度に。記事とピンは取れなくてもプロフィール
    // 本体は出す(投稿の失敗だけは下の catch でエラーにする)。
    const [posts, articles, pins] = await Promise.all([
      getAccountStatuses(account.id, {}),
      getAccountStatuses(account.id, { articles: true }).catch(() => emptyPage),
      getAccountStatuses(account.id, { pinned: true }).catch(() => emptyPage)
    ]);

    return { acct, account, me, rel, posts, articles, pins, error: null as string | null };
  } catch (e) {
    const msg = e instanceof Error ? e.message : '';
    return { acct, account: null, me: null, rel: null, posts: emptyPage, articles: emptyPage, pins: emptyPage, error: msg };
  }
}
