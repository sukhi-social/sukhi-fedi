// SPDX-License-Identifier: AGPL-3.0-or-later
// Web Push の、ブラウザにも gateway にも触らない部分。旧 web の web/src/lib/push.ts と同じ約束。
//
// **鳴っていい種類は、gateway が決める**(WebPush.direct_types/0)。ここは、instance の返事から
// 一覧を読んで、そのまま true にするだけ。自分では足さない ── 手元にもう一つ一覧を持つと、
// いつか片方だけ増えて、お気に入りで電話が鳴る。一覧が空なら、何も鳴らさない。

export type PushConfig = { serverKey: string | null; directTypes: string[] };

// /api/v2/instance の返事から、鍵と一覧を取り出す(v1 には configuration が無い)。
// 欠けているものは「やっていない」に倒す。押して何も起きないより、出さないほうがいい。
export function readPushConfig(body: unknown): PushConfig {
  const c = (body as { configuration?: unknown } | null)?.configuration as
    | { vapid?: { public_key?: unknown }; direct_types?: unknown }
    | undefined;
  const key = c?.vapid?.public_key;
  const types = c?.direct_types;
  return {
    serverKey: typeof key === 'string' && key !== '' ? key : null,
    directTypes: Array.isArray(types) ? types.filter((t): t is string => typeof t === 'string') : []
  };
}

export function alertsFor(directTypes: string[]): Record<string, boolean> {
  const alerts: Record<string, boolean> = {};
  for (const type of directTypes) alerts[type] = true;
  return alerts;
}

// 購読の口(/api/v1/push/subscription)が要る scope。押す前に確かめる ── ブラウザの許可は一度しか訊けない。
export function hasPushScope(scope: string | undefined): boolean {
  return (scope ?? '').split(/\s+/).includes('push');
}
