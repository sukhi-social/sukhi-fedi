// SPDX-License-Identifier: AGPL-3.0-or-later
// 通知の「性質」を、ここ一か所に置く。
//
// 通知はふたつの層に分かれる:
//
//   direct  ── mention(返信・DM)と follow_request。会話で、相手が待っている。
//              だから正直に: 数をそのまま出し、届いた瞬間に増える。
//   ambient ── お気に入り・ブースト・フォローなど。うれしいけれど、急ぎではない。
//              だから静かに: 数字を出さず、育つかたち(views/notify.ts の glyph)で見せて、
//              頁と頁の境でだけ更新する。流れてきても画面の前では動かさない
//              ── 変化の瞬間を誰も見ないことが「景色」の条件だから。
//
// 「どこまで見たか」は、gateway の marker(notifications)一本。層ごとの印は持たない
// ── 通知の頁を開いたとき、両方の層を最新まで進めるので、一本で同じ数え方になる。
// 別の端末で見たものを、こちらでもう一度「新着」と数えないための、正本でもある。
//
// ここは頁を描かない。数える・印を読み書きする・流れを読む、だけ(描くのは views/notify.ts と routes/notify.ts)。

import { config } from './config.ts';
import { gwJson } from './gateway.ts';
import type { Ctx } from './http.ts';
import type { Notification, NotificationType } from './types.ts';

export type Tier = 'direct' | 'ambient';

// 鳴っていい(=すぐ出す)種類。gateway の WebPush.direct_types と同じ一覧(server/push.ts が、そちらを読む道)。
// 手元にあるのは、この一つだけ ── 頁のタブ・数え方・流れの選り分けが、みなここを通る。
export const DIRECT: NotificationType[] = ['mention', 'follow_request'];

export const tierOf = (type: NotificationType): Tier => (DIRECT.includes(type) ? 'direct' : 'ambient');

// 通知を読む・片づける呼び出しには、いつもこれを添える。gateway は、アカウントの設定より
// 遅く・まとめる側にだけ、これを効かせる(置くのも、同じ反応を一つにまとめるのも、gateway がやる)。
// 数えるときも同じ道を通る ── 頁に出ないものを、数えないために。
export const pace = (): Record<string, string> => ({
  hold_minutes: String(config.notifyHoldMin),
  grouping: 'true'
});

// snowflake の id は、桁の違う十進文字列。長さ→辞書順で比べる。
export const newer = (id: string, than: string): boolean => (id.length === than.length ? id > than : id.length > than.length);

// 通知の頁の「新しい通知は、ここまで」の線。新しい順に並ぶので、新着は先頭に固まる。
// 境いは「最後の新着」と「最初の既読」のあいだ。返すのは、線を引く位置(その番号の行のあと。-1 は、先頭の前)。
// 引かないなら null。頁をまたぐので:
//   ・この頁が、ぜんぶ新着で、次の頁がある  → 境いは次の頁(まだ引かない)
//   ・この頁に新着が無く、前の頁の最後が新着 → 境いは、この頁の先頭の前
export function dividerAfter(items: { id: string }[], since: string | null, prevId: string | null, hasMore: boolean): number | null {
  if (since === null || items.length === 0) return null;
  let last = -1;
  while (last + 1 < items.length && newer(items[last + 1].id, since)) last++;
  if (last === items.length - 1) return hasMore ? null : last;
  if (last === -1) return prevId !== null && newer(prevId, since) ? -1 : null;
  return last;
}

async function recent(ctx: Ctx, limit: number): Promise<Notification[]> {
  return gwJson<Notification[]>(ctx, 'GET', '/api/v1/notifications', { query: { limit: String(limit), ...pace() } });
}

// 印は無いこともある(まだ一度も置いていない)。そのときは null。
export async function markerOf(ctx: Ctx): Promise<string | null> {
  const r = await gwJson<{ notifications?: { last_read_id?: string } }>(ctx, 'GET', '/api/v1/markers', {
    query: { 'timeline[]': 'notifications' }
  });
  return r.notifications?.last_read_id ?? null;
}

export async function putMarker(ctx: Ctx, id: string): Promise<void> {
  await gwJson(ctx, 'POST', '/api/v1/markers', { json: { notifications: { last_read_id: id } } });
}

/**
 * 層ごとの、まだ見ていない数。最新の一ページ(40)から数える ── 上限はそこ。
 *
 * はじめて(印がまだ無い)のときは、「いま」を起点にする。過去の分で、いきなり数が立たないように。
 * 一件も無いなら '0'(何も見ていない)を置く ── 空のまま置かずにおくと、最初の一件が来たとき、
 * それも「いま」に呑まれて、見たことになってしまう。
 */
export async function unseen(ctx: Ctx): Promise<Record<Tier, number>> {
  const [marker, items] = await Promise.all([markerOf(ctx), recent(ctx, 40)]);
  if (marker === null) {
    await putMarker(ctx, items[0]?.id ?? '0');
    return { direct: 0, ambient: 0 };
  }
  const count: Record<Tier, number> = { direct: 0, ambient: 0 };
  for (const n of items) if (newer(n.id, marker)) count[tierOf(n.type)]++;
  return count;
}

/** 通知の頁を開いたとき。両方の層を、いま見える最新まで「見た」にする。 */
export async function markSeen(ctx: Ctx): Promise<void> {
  const [top] = await recent(ctx, 1);
  if (top) await putMarker(ctx, top.id);
}

// ── gateway の流れ(SSE)を読む ──────────────────────────────────────
// `event:` と `data:` を集めて、空行で一フレーム。コメント行(:thump の心拍)は素通り。
export async function* frames(body: ReadableStream<Uint8Array>): AsyncGenerator<{ event: string; data: string }> {
  const decoder = new TextDecoder();
  let buf = '';
  let event = '';
  let data = '';
  for await (const chunk of body) {
    buf += decoder.decode(chunk, { stream: true });
    let nl: number;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).replace(/\r$/, '');
      buf = buf.slice(nl + 1);
      if (line === '') {
        if (event && data) yield { event, data };
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
