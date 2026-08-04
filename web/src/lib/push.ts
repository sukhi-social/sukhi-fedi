// Web Push の、ブラウザに触らない部分。
//
// 鍵の詰め替えと、どの通知で鳴らすかの組み立て。どちらも黙って間違える
// たちのもの ── 鍵が一バイトずれても subscribe() はエラーを出さず、
// ただ何も鳴らなくなる。だから純粋な形にして、試験を置いておく。
//
// ブラウザを触るほうは push.svelte.ts。

/**
 * VAPID の公開鍵(base64url の文字列)を、`pushManager.subscribe()` が
 * 求める生のバイト列にする。
 *
 * base64url は `-` `_` を使い、詰め物(`=`)を省く。`atob` はそのどちらも
 * 知らないので、標準の綴りに直してから渡す。ここを飛ばすと `atob` が
 * 投げるか、もっと悪いことに**通ってしまって**、鍵が静かに壊れる。
 */
export function decodeServerKey(base64url: string): Uint8Array<ArrayBuffer> {
  const padded = base64url.padEnd(base64url.length + ((4 - (base64url.length % 4)) % 4), '=');
  const standard = padded.replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(standard);

  // `new Uint8Array(n)` から詰めるのは、返す型を ArrayBuffer 付きにする
  // ため ── `pushManager.subscribe()` の applicationServerKey は
  // SharedArrayBuffer backed を受け取らない。
  const bytes = new Uint8Array(new ArrayBuffer(raw.length));
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

/**
 * サーバに送る `alerts`。
 *
 * **鳴っていい種類は、サーバが決める。**ここは受け取った一覧をそのまま
 * true にするだけで、自分では足さない ── 手元にもう一つ一覧を持つと、
 * いつか片方だけ増えて、静かに約束が破れる(お気に入りで電話が鳴る)。
 *
 * 一覧が空で来たら、何も鳴らさない。分からないときに鳴らすより、
 * 鳴らさないほうがいい。
 */
export function alertsFor(directTypes: string[]): Record<string, boolean> {
  const alerts: Record<string, boolean> = {};
  for (const type of directTypes) alerts[type] = true;
  return alerts;
}

/**
 * `/api/v2/instance` の返事から、鍵と一覧を取り出す。
 *
 * 取り出すだけを切り離してあるのは、ここを一度まちがえたから ── v1 を
 * 見ていて、v1 には configuration がまるごと無かった。**パネルは正しく
 * 隠れた**ので、動いているように見えていた。鍵を置いた日に、はじめて
 * 「ずっと出ない」と分かるたぐいの間違い。
 *
 * 欠けているものは「やっていない」に倒す。出さないほうが、押して何も
 * 起きないよりいい。
 */
export function readPushConfig(body: unknown): { serverKey: string | null; directTypes: string[] } {
  const config = (body as { configuration?: unknown })?.configuration as
    | { vapid?: { public_key?: unknown }; direct_types?: unknown }
    | undefined;

  const key = config?.vapid?.public_key;
  const types = config?.direct_types;

  return {
    serverKey: typeof key === 'string' && key !== '' ? key : null,
    directTypes: Array.isArray(types) ? types.filter((t): t is string => typeof t === 'string') : []
  };
}

/** ブラウザがこの機械で push を扱えるか。 */
export function pushSupported(): boolean {
  return (
    typeof window !== 'undefined' &&
    'serviceWorker' in navigator &&
    'PushManager' in window &&
    'Notification' in window
  );
}
