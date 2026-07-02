// WebTransport でエッジ(karutte, webtransport.f3liz.casa)に繋ぎ、live なタイムライン更新を
// 受ける。sukhi が NATS に出す新規投稿を karutte が feed ごとの stream で押してくるので、
// ここは「届いた status を onStatus に渡す」だけ。SSE(notify.ts)と同じ静かな再接続。
//
// 非対応ブラウザ(WebTransport 無し)や接続失敗のときは黙って何もしない ── SSE と
// 再接続時の refetch がフォールバックとして残る。
import { loadToken } from '$lib/auth';

type OnStatus = (status: unknown) => void;

const BASE_BACKOFF = 1_000;
const MAX_BACKOFF = 30_000;

/**
 * live タイムライン stream を張る。返り値を呼ぶと止まる。WebTransport が無い環境では
 * 何もしないダミーを返す(呼び出し側は気にしなくてよい)。
 */
export function startTimelineStream(onStatus: OnStatus): () => void {
  if (typeof WebTransport === 'undefined' || typeof window === 'undefined') {
    return () => {};
  }
  const ac = new AbortController();
  void run(ac, onStatus);
  return () => ac.abort();
}

async function run(ac: AbortController, onStatus: OnStatus): Promise<void> {
  let backoff = BASE_BACKOFF;

  while (!ac.signal.aborted) {
    const t = loadToken();
    if (!t) break;

    let wt: WebTransport | null = null;
    let onAbort: (() => void) | null = null;

    try {
      // 発券: sukhi が Ed25519 署名した短命チケット＋接続先を返す。
      const res = await fetch('/api/wt', {
        headers: { authorization: `Bearer ${t.access_token}` },
        signal: ac.signal
      });
      if (res.status === 401) break;
      if (!res.ok) throw new Error(`wt_${res.status}`);
      const { endpoint, ticket } = await res.json();
      if (ac.signal.aborted) break;

      wt = new WebTransport(`${endpoint}?ticket=${encodeURIComponent(ticket)}`);
      const conn = wt;
      // ready / closed は誰かが必ず握っておく。握らないと、接続中に close() された
      // とき（ページ遷移で cleanup が走る等）に "Uncaught (in promise)
      // WebTransportError: close() called on WebTransport while connecting" になる。
      // await 側でも拾うが、closed は誰も待たないので no-op で握る。
      conn.ready.catch(() => {});
      conn.closed.catch(() => {});
      // 離脱時は接続中でも即閉じる（上の catch がその拒否を無害化する）。
      onAbort = () => safeClose(conn);
      ac.signal.addEventListener('abort', onAbort, { once: true });

      await conn.ready;
      if (ac.signal.aborted) break;
      // つながった。待ちを最短に戻す。
      backoff = BASE_BACKOFF;

      await readStreams(conn, onStatus, ac.signal);
    } catch {
      // 切れたら下でひと呼吸おいて繋ぎ直す。
    } finally {
      if (onAbort) ac.signal.removeEventListener('abort', onAbort);
      if (wt) safeClose(wt);
    }

    if (ac.signal.aborted) break;
    await sleep(backoff, ac.signal);
    backoff = Math.min(backoff * 2, MAX_BACKOFF);
  }
}

// karutte は feed ごとに単方向 stream を開く。届いた stream を並行に読む。
async function readStreams(wt: WebTransport, onStatus: OnStatus, signal: AbortSignal): Promise<void> {
  const reader = wt.incomingUnidirectionalStreams.getReader();
  while (!signal.aborted) {
    const { value, done } = await reader.read();
    if (done) break;
    void readOne(value as ReadableStream<Uint8Array>, onStatus, signal);
  }
}

// 一本の stream = 改行区切りの status JSON。1 行ずつ流す。
async function readOne(stream: ReadableStream<Uint8Array>, onStatus: OnStatus, signal: AbortSignal): Promise<void> {
  const reader = stream.getReader();
  const dec = new TextDecoder();
  let buf = '';
  try {
    while (!signal.aborted) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl: number;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line.trim()) {
          try {
            onStatus(JSON.parse(line));
          } catch {
            /* 壊れた行は捨てる */
          }
        }
      }
    }
  } catch {
    /* stream が切れたら黙って終わる(上位が再接続する) */
  }
}

function safeClose(wt: WebTransport): void {
  try {
    wt.close();
  } catch {
    /* already closed */
  }
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const id = setTimeout(resolve, ms);
    signal.addEventListener('abort', () => {
      clearTimeout(id);
      resolve();
    }, { once: true });
  });
}
