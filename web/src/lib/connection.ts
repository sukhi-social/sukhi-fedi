// つながりが戻ったことに気づくための、小さな一箇所。
//
// サーバの再起動や回線の一瞬の切断で読み込みが失敗したとき、ビューは
// エラーを抱えたまま固まってしまう。ここは「いま繋ぎ直すなら今だよ」の
// 合図(`reconnect`)を一本だけ出す ── オンライン復帰と、裏にいたタブが
// 戻ってきた瞬間。エラー中のビューはこれを見て、待たずに自分を読み直す。
//
// 通知 SSE(notify.ts)も同じ二つの合図で起こしているが、あちらは
// 自前のループを持つので別仕立て。こちらは fetch ベースのビュー向け。
import { readable } from 'svelte/store';

// online 復帰・タブ復帰のたびに増える数。値そのものに意味はなく、
// 「変わった」ことだけが合図。
export const reconnect = readable(0, (set) => {
  if (typeof window === 'undefined') return;

  let n = 0;
  const poke = () => set((n += 1));
  const onVisible = () => {
    if (!document.hidden) poke();
  };

  window.addEventListener('online', poke);
  document.addEventListener('visibilitychange', onVisible);

  return () => {
    window.removeEventListener('online', poke);
    document.removeEventListener('visibilitychange', onVisible);
  };
});

// 前に出ているあいだだけ、ゆっくり打つ合図。`reconnect` と同じ形
// (増える数。値でなく「変わった」ことが合図)。
//
// DM には live の床が無い ── 管が死んでいても、こちらからは「静か」と
// 見分けがつかない。**タブは開きっぱなし・管は死んでいる**が、気づかれ
// ない一番長い窓になる。ここが最後の砦。
//
// 裏に回ったら止める(電池と回線を無駄にしない)。速くしない ── 速い
// polling は「平穏」ではなく「監視」になる。live の代用ではなく、保険。
export function slowPoll(everyMs = 60_000) {
  return readable(0, (set) => {
    if (typeof window === 'undefined') return;

    let n = 0;
    let id: ReturnType<typeof setInterval> | null = null;

    const start = () => {
      if (id === null) id = setInterval(() => set((n += 1)), everyMs);
    };
    const stop = () => {
      if (id !== null) clearInterval(id);
      id = null;
    };
    const onVisibility = () => (document.hidden ? stop() : start());

    onVisibility();
    document.addEventListener('visibilitychange', onVisibility);

    return () => {
      stop();
      document.removeEventListener('visibilitychange', onVisibility);
    };
  });
}

// この失敗は「繋がらない」たぐいか(=戻れば直る)。本当のエラー
// (404 や 422)とは分けて、静かな「待っています」表示＋自動再試行に
// まわすために使う。
//
// req() が投げるのは:
//   * fetch 自体の reject(オフライン) → TypeError、ブラウザごとに文言差
//   * `gateway_not_connected` → API は生きているがゲートウェイ再起動中
//   * `<label>_failed_<status>` → 5xx / 0 は一時的とみなす
export function isConnectivityError(e: unknown): boolean {
  const msg = e instanceof Error ? e.message : '';

  return (
    msg === 'gateway_not_connected' ||
    msg === 'Failed to fetch' || // Chromium
    msg === 'Load failed' || // WebKit / Safari
    msg === 'NetworkError when attempting to fetch resource.' || // Firefox
    /_failed_(5\d\d|0)$/.test(msg)
  );
}

// エラー中のビューを、つながりが戻るまで静かに叩き直す小さな仕掛け。
// `reload` は読み直しの一回分。使う側は、接続エラーで失敗したら `fail()`、
// 成功したら `ok()`、ビューを畳むとき `stop()` を呼ぶ。
//
// 起こし方は二つ: online/タブ復帰の合図(待たずに即)と、誰も画面を
// 離れないまま落ちている場合に備えた、伸びる間隔のタイマー。どちらも
// 「いま待ち状態のとき」だけ動く。
const BASE_RETRY = 1_000;
const MAX_RETRY = 15_000;

export function autoRetry(reload: () => void) {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let delay = BASE_RETRY;

  const clear = () => {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
  };

  // online/タブ復帰: 待ち状態なら待たずに、間隔も最短に戻して読み直す。
  const unsub = reconnect.subscribe((n) => {
    if (n > 0 && timer) {
      delay = BASE_RETRY;
      clear();
      reload();
    }
  });

  return {
    fail() {
      clear();
      timer = setTimeout(() => {
        delay = Math.min(delay * 2, MAX_RETRY);
        reload();
      }, delay);
    },
    ok() {
      delay = BASE_RETRY;
      clear();
    },
    stop() {
      clear();
      unsub();
    }
  };
}
