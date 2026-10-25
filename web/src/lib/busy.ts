// 混雑の応答(429 / 503)をどう読むか ── 画面にも状態にも触れない部分。
// 置き場は busy.svelte.ts。ここは node の試験でそのまま動かせるように分けた。

const MIN_SECONDS = 1;
const MAX_SECONDS = 300;
const FALLBACK_SECONDS = 5;

export function isBusyStatus(status: number): boolean {
  return status === 429 || status === 503;
}

// 待つ秒数: ヘッダ → 本文の `retry_after` → 既定、の順。範囲に収める
// (0 だと即座に叩き直し、巨大だと画面が居座る)。
export function retrySeconds(header: string | null, body: unknown): number {
  const fromHeader = header === null ? NaN : Number(header);
  const fromBody =
    typeof body === 'object' && body !== null && 'retry_after' in body
      ? Number((body as { retry_after: unknown }).retry_after)
      : NaN;
  const n = [fromHeader, fromBody].find((x) => Number.isFinite(x) && x > 0) ?? FALLBACK_SECONDS;
  return Math.min(MAX_SECONDS, Math.max(MIN_SECONDS, Math.ceil(n)));
}

// 「ゆっくりさせてね」の間、リクエストの開始を、この間隔より詰めない。
// 500 回/分の枠に対して 1 秒に 1 回(60 回/分)なら、慌てなくても超えない。
export const SLOW_GAP_MS = 1000;

// ゆっくりのあいだ、次のリクエストをいつ始めてよいか。`slowUntil` を過ぎて
// いれば待たない。`nextFree` は、前のリクエストの後ろに並ぶ位置。
export function slotFor(
  now: number,
  slowUntil: number,
  nextFree: number,
  gap: number = SLOW_GAP_MS
): { wait: number; nextFree: number } {
  if (now >= slowUntil) return { wait: 0, nextFree: now };
  const start = Math.max(now, nextFree);
  return { wait: start - now, nextFree: start + gap };
}

// 本文の `reason`(おいたはダメだよ〜 のような、人向けのひとこと)。
export function reasonText(body: unknown): string | null {
  if (typeof body !== 'object' || body === null || !('reason' in body)) return null;
  const r = (body as { reason: unknown }).reason;
  return typeof r === 'string' && r.trim() !== '' ? r.trim().slice(0, 200) : null;
}

// ── 待機列 ──
// 混んでいるとき、サーバは 503 に「整理券」を付けて返す(`error: "queued"`、
// 本文の `queue.ticket` と `retry_after_ms`)。画面には出さず、api.ts が
// 言われた時間だけ待って、同じリクエストに `x-queue-ticket` を付けて送り直す。
// 順番が来るまで、それを繰り返す。

export const QUEUE_TICKET_HEADER = 'x-queue-ticket';
// 待つのは、合計でこの長さまで。過ぎたら、ふつうの 503(混雑の知らせ)に戻す。
export const QUEUE_PATIENCE_MS = 30_000;
const QUEUE_MIN_MS = 100;
const QUEUE_MAX_MS = 10_000;

export type QueueTicket = { ticket: number; waitMs: number };

export function queueTicket(body: unknown): QueueTicket | null {
  if (typeof body !== 'object' || body === null) return null;
  const b = body as { error?: unknown; queue?: { ticket?: unknown }; retry_after_ms?: unknown };
  if (b.error !== 'queued') return null;
  const ticket = Number(b.queue?.ticket);
  if (!Number.isInteger(ticket) || ticket <= 0) return null;
  const ms = Number(b.retry_after_ms);
  const waitMs = Math.min(QUEUE_MAX_MS, Math.max(QUEUE_MIN_MS, Number.isFinite(ms) ? ms : 1000));
  return { ticket, waitMs };
}
