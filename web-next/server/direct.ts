// SPDX-License-Identifier: AGPL-3.0-or-later
// ふたりの部屋の呼び鈴。gateway の WebSocket(`/api/v1/streaming?stream=direct`)を、
// この郵便局が開いて、「この部屋に何か起きた」だけを読む。
//
// ブラウザではなく、ここで開く理由:
//   ・ブラウザは、WebSocket の握手に Authorization を付けられず、token を URL に乗せるしかない
//     (履歴やログに残りうる)。この郵便局なら、Bearer を header に付けられる ── token は URL に出ない。
//   ・ブラウザに token が無い、という郵便局の約束(server/session.ts)を、live でも崩さない。
//
// 中身は渡さない。部屋の頁が、API に訊き直す(server/sse.ts)。

import { config } from './config.ts';

/**
 * 流れてきた一通が、この会話のことか。`conversation` のフレームで、payload の id が同じなら true。
 * 読めない形は false ── 分からないものを合図と見なして API を叩きつづけるより、静かにしているほうがいい。
 */
export function isThisConversation(raw: unknown, conversationId: string): boolean {
  if (typeof raw !== 'string') return false;
  try {
    const frame = JSON.parse(raw) as { event?: string; payload?: unknown };
    if (frame.event !== 'conversation') return false;
    const payload = typeof frame.payload === 'string' ? JSON.parse(frame.payload) : frame.payload;
    return String((payload as { id?: unknown } | null)?.id ?? '') === String(conversationId);
  } catch {
    return false;
  }
}

/**
 * `stream=direct` を開いて、この会話に何か起きたら `ring` を呼ぶ。向こうが切れたら終わる。
 * `gone` が立ったら、こちらから閉じる。
 */
export function watchDirect(token: string, conversationId: string, ring: () => void, gone: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const url = new URL('/api/v1/streaming', config.gateway);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('stream', 'direct');

    let ws: WebSocket;
    try {
      // Node の WebSocket(undici)は、握手の header を足せる(ブラウザの WebSocket には無い口)。
      ws = new WebSocket(url, { headers: { authorization: `Bearer ${token}` } });
    } catch {
      resolve();
      return;
    }

    const stop = () => {
      try {
        ws.close();
      } catch {
        // もう閉じている。
      }
    };
    ws.onmessage = (ev) => {
      if (isThisConversation(ev.data, conversationId)) ring();
    };
    // onerror のあとには、かならず onclose が来る。ここでは何もしない。
    ws.onerror = () => {};
    ws.onclose = () => {
      gone.removeEventListener('abort', stop);
      resolve();
    };

    if (gone.aborted) stop();
    else gone.addEventListener('abort', stop, { once: true });
  });
}
