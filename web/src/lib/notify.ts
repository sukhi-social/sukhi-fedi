// 通知の「性質」はぜんぶここに置く。
//
// 通知はふたつの層に分かれる:
//
//   direct  — mention(返信・DM)と follow_request。会話で、相手が
//             待っている。だから正直に: 数をそのまま出し、SSE で
//             届いた瞬間に増える。
//   ambient — favourite・reblog・follow など。嬉しいけれど、急ぎでは
//             ない。だから静かに: 数字を出さず、育つかたち
//             (NotifGlyph)で見せて、ページ遷移の境界でだけ更新する。
//             流れてきても画面の前では動かさない — 変化の瞬間を
//             誰も見ないことが「景色」の条件だから。
//
// 「どこまで見たか」は層ごとに localStorage で覚える(この端末の
// 景色は、この端末のもの)。通知ページ(ベル)を開いたとき markAllSeen で
// 両方とも最新まで進める ── 見に来たら気配は消える。
import { writable } from 'svelte/store';
import { getNotifications, type Notification, type NotificationType } from './api';
import { loadToken } from './auth';

export type Tier = 'direct' | 'ambient';

// **この一覧の正本はサーバにある**(WebPush の @direct_types)。同じ一覧が
// 「その通知は人の携帯を鳴らしていいか」も決めているので、手元に二つ目の
// リテラルを置くと、いつか片方だけ増えて、静かに約束が破れる ── お気に入りで
// 電話が鳴る、というかたちで。
//
// ここにあるのは、サーバに訊く前の暫定値。/api/v1/push/subscription が
// direct_types を返したら adoptDirectTypes() が置き換える。ずれているあいだも
// 違うのは見えかた(数字か、育つかたちか)だけで、鳴る鳴らないはサーバの側。
let directTypes: string[] = ['mention', 'follow_request'];

/** サーバの一覧に合わせる。空や欠けは無視して、暫定値のままにする。 */
export function adoptDirectTypes(fromServer: string[] | undefined | null): void {
  if (Array.isArray(fromServer) && fromServer.length > 0) directTypes = fromServer;
}

export function tierOf(type: NotificationType): Tier {
  return directTypes.includes(type) ? 'direct' : 'ambient';
}

/** いまの一覧。通知ページが API の絞りこみに使う。 */
export function directTypeList(): NotificationType[] {
  return directTypes as NotificationType[];
}

// まだ見ていない数。AppNav がこれを描く。
export const directUnseen = writable(0);
export const ambientUnseen = writable(0);

const SEEN_KEY: Record<Tier, string> = {
  direct: 'sf.seen.direct',
  ambient: 'sf.seen.ambient'
};

// snowflake id は桁の違う十進文字列。長さ→辞書順で比べる。
function newerThan(id: string, seen: string): boolean {
  return id.length === seen.length ? id > seen : id.length > seen.length;
}

/**
 * 最新の一ページを取って、層ごとの未見数を数えなおす。
 * AppNav がページ遷移の境界で呼ぶ — ambient の表示が動くのは
 * ここだけ。初めての端末では「いま」を起点にする(過去の分で
 * いきなり木が立たないように)。
 */
export async function refreshUnseen(): Promise<void> {
  let items: Notification[];
  try {
    items = (await getNotifications({ limit: 40 })).items;
  } catch {
    // 取れなかったら、表示は前のまま。そっとしておく。
    return;
  }

  const counts: Record<Tier, number> = { direct: 0, ambient: 0 };
  const newest: Partial<Record<Tier, string>> = {};

  for (const n of items) {
    const tier = tierOf(n.type);
    newest[tier] ??= n.id;
    const seen = localStorage.getItem(SEEN_KEY[tier]);
    if (seen === null || newerThan(n.id, seen)) counts[tier]++;
  }

  for (const tier of ['direct', 'ambient'] as const) {
    const id = newest[tier];
    if (id && localStorage.getItem(SEEN_KEY[tier]) === null) {
      localStorage.setItem(SEEN_KEY[tier], id);
      counts[tier] = 0;
    }
  }

  directUnseen.set(counts.direct);
  ambientUnseen.set(counts.ambient);
}

/** 仕切り棒のために、いまの「見た」位置を読む(進める前に控える)。 */
export function seenId(tier: Tier): string | null {
  return localStorage.getItem(SEEN_KEY[tier]);
}

/** id が seen より新しいか。seen が無い(初回)ときは新着扱いにしない。 */
export function isNewer(id: string, seen: string | null): boolean {
  return seen !== null && newerThan(id, seen);
}

/**
 * ベルを開いたとき。反応タブをわざわざ開かなくても、通知を見に来たら
 * 両方の層を「いまの最新まで見た」にして気配を戻す。最新 id は直近の
 * 一ページから層ごとに拾う ── refreshUnseen と同じ見方なので、「来て
 * いないのに、がつく」ズレも起きない。
 */
export async function markAllSeen(): Promise<void> {
  let items: Notification[];
  try {
    items = (await getNotifications({ limit: 40 })).items;
  } catch {
    // 取れなくても、表示だけはそっと戻す(次の遷移で数えなおす)。
    directUnseen.set(0);
    ambientUnseen.set(0);
    return;
  }

  const newest: Partial<Record<Tier, string>> = {};
  for (const n of items) newest[tierOf(n.type)] ??= n.id;
  for (const tier of ['direct', 'ambient'] as const) {
    const id = newest[tier];
    if (id) localStorage.setItem(SEEN_KEY[tier], id);
  }

  directUnseen.set(0);
  ambientUnseen.set(0);
}

/** 「すべて消す」のあと。サーバ側が空なので、両方の数も空に。 */
export function clearCounts(): void {
  directUnseen.set(0);
  ambientUnseen.set(0);
}

// ── direct の SSE ────────────────────────────────────────────────────
// /api/v1/streaming/user/notification を一本だけ開いておく。
// EventSource は Authorization ヘッダを付けられない(token を URL に
// 出したくない)ので、fetch のストリームを自前で読む。
// direct だけがここで動く。ambient は流れてきても無視 — 次の遷移で
// refreshUnseen が数えなおすから、取りこぼしはない。

let streamAbort: AbortController | null = null;

// 切れたあとの待ち時間。最初は短く、繰り返し失敗するほど伸ばし、
// つながった瞬間にまた短く戻す ── reboot のときは数秒で戻り、本当に
// 落ちているときだけ間隔があく。
const BASE_BACKOFF = 1_000;
const MAX_BACKOFF = 30_000;

// 「いますぐ繋ぎ直して」の合図。オンライン復帰やタブ復帰のとき、
// バックオフの待ちを途中で起こすために使う。
const wake = new EventTarget();
let wakeWired = false;

function pokeReconnect(): void {
  wake.dispatchEvent(new Event('wake'));
}

function wireWake(): void {
  if (wakeWired || typeof window === 'undefined') return;
  wakeWired = true;
  // オフライン→オンラインに戻った瞬間。
  window.addEventListener('online', pokeReconnect);
  // 寝ていたタブに戻ってきた瞬間 ── 裏にいる間に切れていることが多い。
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) pokeReconnect();
  });
}

export function startStream(): void {
  if (streamAbort) return;
  wireWake();
  const ac = new AbortController();
  streamAbort = ac;
  void run(ac);
}

export function stopStream(): void {
  streamAbort?.abort();
  streamAbort = null;
}

async function run(ac: AbortController): Promise<void> {
  let backoff = BASE_BACKOFF;

  while (!ac.signal.aborted) {
    const t = loadToken();
    if (!t) break;

    try {
      const res = await fetch('/api/v1/streaming/user/notification', {
        headers: {
          accept: 'text/event-stream',
          authorization: `Bearer ${t.access_token}`
        },
        signal: ac.signal
      });
      // token が死んでいるなら叩き続けない。ログアウトは authed な
      // 通常リクエスト側が気づいて片づける。
      if (res.status === 401) break;
      if (!res.ok || !res.body) throw new Error(`stream_${res.status}`);

      // つながった。待ち時間を最短に戻し、切れている間に来たぶんを
      // 数えなおす ── live の増分は切断中は届かないので、ここで
      // サーバの真値に合わせる(取りこぼしの回収)。
      backoff = BASE_BACKOFF;
      void refreshUnseen();

      await readEvents(res.body, ac.signal);
    } catch {
      // 切れたら下でひと呼吸おいて、つなぎなおす。
    }

    if (ac.signal.aborted) break;
    // ひと呼吸。online/タブ復帰の合図が来たら待たずに起きる。
    await sleep(backoff, ac.signal);
    backoff = Math.min(backoff * 2, MAX_BACKOFF);
  }

  // break で出たとき(token 切れなど)、死んだ controller を握った
  // ままだと次の startStream が始められない。手を放しておく。
  if (streamAbort === ac) streamAbort = null;
}

// SSE の枠組みだけの小さな読み手。`event:` と `data:` を集めて、
// 空行で一フレーム。コメント行(ハートビート ":thump")は素通り。
async function readEvents(body: ReadableStream<Uint8Array>, signal: AbortSignal): Promise<void> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buf = '';
  let event = '';
  let data = '';

  for (;;) {
    const { done, value } = await reader.read();
    if (done || signal.aborted) return;
    buf += decoder.decode(value, { stream: true });

    let nl: number;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).replace(/\r$/, '');
      buf = buf.slice(nl + 1);

      if (line === '') {
        if (event && data) onEvent(event, data);
        event = '';
        data = '';
      } else if (line.startsWith('event:')) {
        event = line.slice(6).trim();
      } else if (line.startsWith('data:')) {
        data += line.slice(5).trim();
      }
    }
  }
}

function onEvent(event: string, data: string): void {
  if (event !== 'notification') return;
  try {
    const n = JSON.parse(data) as Notification;
    if (tierOf(n.type) === 'direct') directUnseen.update((c) => c + 1);
  } catch {
    // 形がちがうフレームは、読めなかったことにする。
  }
}

// タイマー満了・abort・「いますぐ繋ぎ直して」のどれかで起きる待ち。
function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) return resolve();

    const done = () => {
      clearTimeout(id);
      signal.removeEventListener('abort', done);
      wake.removeEventListener('wake', done);
      resolve();
    };

    const id = setTimeout(done, ms);
    signal.addEventListener('abort', done, { once: true });
    wake.addEventListener('wake', done, { once: true });
  });
}
