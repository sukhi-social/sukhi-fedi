// DM の live の管。
//
// **これは呼び鈴で、荷物ではない。** 鳴ったら「見にいって」と言うだけで、
// 中身は API に訊き直す。理由は二つ:
//
//   ・切れているあいだに来たぶんは、管には流れてこない。呼び鈴を荷物に
//     すると、切れた時間ぶんが穴になる。API に訊けば穴は埋まる。
//   ・同じ一通が三つの道から来る(自分の送信の返り値 / 拾い直し / ここ)。
//     形を一つにしておけば、潰す場所も一つで済む。
//
// 60 秒の見直しは残す。管が死んでいることに、こちらからは気づけない
// ── 「静か」と見分けがつかないので。あちらが最後の砦で、ここは速さ。
//
// token は URL に乗る。ブラウザは WebSocket の握手に Authorization を
// 付けられないので、ほかに道が無い(Mastodon も同じ)。同じ経路の https
// なので中身は暗号のうちだけれど、履歴やログに残りうるのは本当のこと。

import { loadToken } from './auth';
import { isThisConversation } from './direct';

const BASE_BACKOFF = 1_000;
const MAX_BACKOFF = 30_000;

/**
 * `stream=direct` を開いて、この会話に何か起きたら `onPoke` を呼ぶ。
 *
 * 返るのは畳む手。会話の面を離れるとき呼ぶ。
 */
export function watchDirect(conversationId: string, onPoke: () => void): () => void {
  if (typeof window === 'undefined') return () => {};

  let socket: WebSocket | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let backoff = BASE_BACKOFF;
  let closed = false;

  const open = () => {
    if (closed) return;
    const t = loadToken();
    if (!t) return;

    const url = new URL('/api/v1/streaming', window.location.origin);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('stream', 'direct');
    url.searchParams.set('access_token', t.access_token);

    let ws: WebSocket;
    try {
      ws = new WebSocket(url);
    } catch {
      retry();
      return;
    }
    socket = ws;

    ws.onopen = () => {
      // つながった。次に切れたときは、また短い待ちから。
      backoff = BASE_BACKOFF;
    };

    ws.onmessage = (ev) => {
      if (!isThisConversation(ev.data, conversationId)) return;
      onPoke();
    };

    ws.onclose = () => {
      if (socket === ws) socket = null;
      retry();
    };

    // onerror のあとは必ず onclose が来る。二重に繋ぎ直さない。
    ws.onerror = () => {};
  };

  const retry = () => {
    if (closed || timer) return;
    timer = setTimeout(() => {
      timer = null;
      open();
    }, backoff);
    backoff = Math.min(backoff * 2, MAX_BACKOFF);
  };

  // 裏に回ったら畳む。開いたままの WebSocket は、寝ている端末の電池を
  // 静かに減らす ── そして裏にいるあいだは、そもそも誰も見ていない。
  const onVisibility = () => {
    if (document.hidden) {
      socket?.close();
      socket = null;
    } else if (!socket) {
      backoff = BASE_BACKOFF;
      open();
    }
  };

  document.addEventListener('visibilitychange', onVisibility);
  open();

  return () => {
    closed = true;
    document.removeEventListener('visibilitychange', onVisibility);
    if (timer) clearTimeout(timer);
    socket?.close();
    socket = null;
  };
}
