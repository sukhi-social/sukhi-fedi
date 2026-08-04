// 「知らせを受け取る」の、状態と手つづき。
//
// 押しつけない ── 起動時に許可を訊いたりしない。設定でその人が入れたときだけ
// ブラウザに訊く。これは人を起こせる唯一の道なので、始めるのはこちらでは
// なく、その人の側。
//
// 純粋な部分は push.ts にある(鍵の詰め替えと alerts)。ここはブラウザに
// 触るところだけ。

import {
  deletePushSubscription,
  getPushConfig,
  getPushSubscription,
  putPushSubscription
} from '$lib/api';
import { loadToken } from '$lib/auth';
import { adoptDirectTypes } from '$lib/notify';
import { alertsFor, decodeServerKey, pushSupported } from '$lib/push';

export type PushState =
  | 'unsupported' // このブラウザ・この機械では、そもそも扱えない
  | 'unconfigured' // サーバに VAPID 鍵が無い。押せる口を出さない
  | 'denied' // ブラウザで拒否済み。設定から戻すしかない
  | 'reauth' // いまの token に push の許しが無い。入りなおしが要る
  | 'off'
  | 'on'
  | 'working';

// 購読の口(/api/v1/push/subscription)が要る scope。
//
// **押す前に確かめる。** 無いまま進むと、ブラウザの許可 ── 一度しか
// 訊けないもの ── を使ったあとでサーバに 403 で断られて、手元からは
// 「うまくいきませんでした」としか見えない。それは直しようのない案内。
function hasPushScope(): boolean {
  const t = loadToken();
  return !!t && t.scope.split(/\s+/).includes('push');
}

export function createPush() {
  let state = $state<PushState>('working');
  let error = $state<string | null>(null);

  // サーバの一覧。手元では作らない ── どれが人を起こしていいかは
  // サーバの決めごとなので([[deliverable?/3]])。
  let directTypes = $state<string[]>([]);

  async function refresh() {
    if (!pushSupported()) {
      state = 'unsupported';
      return;
    }

    // **鍵の有無は、購読より先に確かめる。** /push/subscription は購読が
    // 無いと 404 なので、そこだけ見ていると「このサーバは push をやって
    // いない」と「まだ購読していない」が見分けられない。見分けずに釦を
    // 出すと、ブラウザの許可を一度きり使ってから「鍵がありません」になる。
    const config = await getPushConfig();
    directTypes = config.directTypes;
    adoptDirectTypes(config.directTypes);

    if (!config.serverKey) {
      state = 'unconfigured';
      return;
    }

    if (Notification.permission === 'denied') {
      state = 'denied';
      return;
    }

    // 許可を訊く**前に**。あとで気づくと、取り返しのつかない一回を使い
    // 終わっている。
    if (!hasPushScope()) {
      state = 'reauth';
      return;
    }

    try {
      const row = await getPushSubscription();

      // サーバに行があっても、このブラウザの購読が消えていることがある
      // (端末を替えた、履歴を消した)。**ブラウザ側を本当のこととする。**
      const reg = await navigator.serviceWorker.getRegistration();
      const live = await reg?.pushManager.getSubscription();
      state = row && live ? 'on' : 'off';
    } catch {
      // 訊けなかっただけ。押せないほうに倒す(嘘の「入っています」より、
      // もう一度押せるほうがいい)。
      state = 'off';
    }
  }

  async function enable() {
    error = null;
    state = 'working';

    if (!hasPushScope()) {
      state = 'reauth';
      return;
    }

    try {
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') {
        state = permission === 'denied' ? 'denied' : 'off';
        return;
      }

      const reg = await navigator.serviceWorker.ready;

      // 鍵は取り直す ── refresh から時間が経っているかもしれないし、
      // 古い鍵で購読すると、送っても復号できないまま静かに落ちる。
      const config = await getPushConfig();
      const serverKey = config.serverKey;
      directTypes = config.directTypes;
      adoptDirectTypes(config.directTypes);

      if (!serverKey) {
        state = 'unconfigured';
        return;
      }

      // 既にあるものは畳んでから。古い鍵で作った購読が残っていると、
      // 送っても復号できないまま静かに落ちる。
      const existing = await reg.pushManager.getSubscription();
      if (existing) await existing.unsubscribe();

      const sub = await reg.pushManager.subscribe({
        // false は選べない ── ブラウザが拒む。押すからには必ず見える。
        userVisibleOnly: true,
        applicationServerKey: decodeServerKey(serverKey)
      });

      const json = sub.toJSON();
      await putPushSubscription({
        endpoint: sub.endpoint,
        keys: { p256dh: json.keys?.p256dh ?? '', auth: json.keys?.auth ?? '' },
        alerts: alertsFor(directTypes)
      });

      state = 'on';
    } catch {
      error = 'failed';
      state = 'off';
    }
  }

  async function disable() {
    error = null;
    state = 'working';

    try {
      const reg = await navigator.serviceWorker.getRegistration();
      const sub = await reg?.pushManager.getSubscription();
      if (sub) await sub.unsubscribe();
      await deletePushSubscription();
    } catch {
      // 片方だけ落ちても、切ったことにする。残った行は、送ろうとした
      // ときの 410 で消える(それが購読の畳まれかた)。
    }

    state = 'off';
  }

  return {
    get state() {
      return state;
    },
    get error() {
      return error;
    },
    get directTypes() {
      return directTypes;
    },
    refresh,
    enable,
    disable
  };
}
