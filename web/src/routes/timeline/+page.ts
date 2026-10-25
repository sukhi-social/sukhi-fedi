// 最初の一枚を load で取る。
//
// ForesightJS はリンクへ向かう意図を予測して `preloadData` を呼ぶので、
// 誰かが「タイムラインへ戻ろう」とマウスを動かした瞬間にこの load が走り、
// クリックしたときにはデータが手元にある ── 読み込み中のままの遷移が、
// 温まった遷移になる。
//
// mount 後の取得は残す(タブ切替・フィルタ・接続が戻ったときの再試行)が、
// 初回はここが始める(待つのは頁。下の load を参照)。prerender は切る ── load が localStorage の
// ログイン状態と生の fetch を触るため、node で走らせない。
import { fetchTimeline, type Page, type Status, type TimelineKind } from '#lib/api.js';
import { isLoggedIn } from '#lib/auth.js';
import { isConnectivityError } from '#lib/connection.js';
import { warmAvatars } from '#lib/avatarWarm.js';

export const prerender = false;
export const ssr = false;

const emptyPage: Page<Status> = { items: [], nextMaxId: null };

export type First = {
  page: Page<Status>;
  failed: boolean;
  offline: boolean;
  unauthorized: boolean;
};

async function fetchFirst(kind: TimelineKind): Promise<First> {
  try {
    const page = await fetchTimeline(kind, {});
    // 「投稿と顔が一緒に現れる」を、待たずに狙う。予測のあいだに走らせて
    // おけば、描くときには温まっている。間に合わなくても本文は出す。
    void warmAvatars(page.items, 1000);
    return { page, failed: false, offline: false, unauthorized: false };
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'unknown';
    return {
      page: emptyPage,
      failed: msg !== 'unauthorized',
      offline: isConnectivityError(e),
      unauthorized: msg === 'unauthorized'
    };
  }
}

// 取得は始めるが、終わるのを待たない。待つと、一枚目の応答が返るまで殻も
// ナビも出ず白紙のまま ── 実測では home の初回が 1.5 秒かかり、その間
// AppNav の verify_credentials なども後ろに並んでいた。Promise のまま
// 渡せば、画面は先に出て、これらの呼び出しも一枚目と並んで走る。先読みで
// 始まった取得は、遷移したときにそのまま使われる。first は reject しない。
export function load() {
  const kind: TimelineKind = isLoggedIn() ? 'home' : 'public';
  return { kind, first: fetchFirst(kind) };
}
