// SPDX-License-Identifier: AGPL-3.0-or-later
// このサーバのカスタム絵文字。めったに変わらないので、五分、手元に置く(押すたびに gateway へ行かない)。
// 取れなかったら、空(絵文字の欄が出ないだけで、何も壊れない)。

import { gwJson } from './gateway.ts';
import type { Ctx } from './http.ts';
import type { Emoji } from './types.ts';

const TTL = 5 * 60_000;
let cached: { at: number; list: Emoji[] } | null = null;

export async function customEmojis(ctx: Ctx): Promise<Emoji[]> {
  if (cached && Date.now() - cached.at < TTL) return cached.list;
  try {
    const all = await gwJson<Emoji[]>(ctx, 'GET', '/api/v1/custom_emojis', { auth: false });
    const list = (Array.isArray(all) ? all : []).filter((e) => e.visible_in_picker !== false && /^[\w-]{1,64}$/.test(e.shortcode));
    cached = { at: Date.now(), list };
    return list;
  } catch {
    return cached?.list ?? [];
  }
}

/** カテゴリごとに、見出しの順(無いものは「ほか」)で。 */
export function byCategory(list: Emoji[]): [string | null, Emoji[]][] {
  const groups = new Map<string | null, Emoji[]>();
  for (const e of list) {
    const k = e.category?.trim() || null;
    groups.set(k, [...(groups.get(k) ?? []), e]);
  }
  return [...groups.entries()].sort((a, b) => (a[0] === null ? 1 : b[0] === null ? -1 : a[0].localeCompare(b[0])));
}
