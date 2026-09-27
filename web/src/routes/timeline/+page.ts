// 最初の一枚を load で取る。
//
// ForesightJS はリンクへ向かう意図を予測して `preloadData` を呼ぶので、
// 誰かが「タイムラインへ戻ろう」とマウスを動かした瞬間にこの load が走り、
// クリックしたときにはデータが手元にある ── 読み込み中のままの遷移が、
// 温まった遷移になる。
//
// mount 後の取得は残す(タブ切替・フィルタ・接続が戻ったときの再試行)が、
// 初回はここが受け持つ。prerender は切る ── load が localStorage の
// ログイン状態と生の fetch を触るため、node で走らせない。
import { fetchTimeline, type Page, type Status, type TimelineKind } from '$lib/api';
import { isLoggedIn } from '$lib/auth';
import { isConnectivityError } from '$lib/connection';
import { warmAvatars } from '$lib/avatarWarm';

export const prerender = false;
export const ssr = false;

const emptyPage: Page<Status> = { items: [], nextMaxId: null };

export async function load() {
  const kind: TimelineKind = isLoggedIn() ? 'home' : 'public';
  try {
    const page = await fetchTimeline(kind, {});
    // 「投稿と顔が一緒に現れる」を、待たずに狙う。予測のあいだに走らせて
    // おけば、描くときには温まっている。間に合わなくても本文は出す。
    void warmAvatars(page.items, 1000);
    return { kind, page, failed: false, offline: false, unauthorized: false };
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'unknown';
    return {
      kind,
      page: emptyPage,
      failed: msg !== 'unauthorized',
      offline: isConnectivityError(e),
      unauthorized: msg === 'unauthorized'
    };
  }
}
