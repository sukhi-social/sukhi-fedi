// 通知を受け取る/やめる の、実際の手続き。設定ページの1ボタンから
// 呼ばれる想定 ── 権限を求めるのは「押した」その場でだけ(ページを
// 開いた瞬間には求めない。ブラウザの許可プロンプトは一度断られると
// 二度と自動では出せなくなるので、押す前の説明は呼び出し側が持つ)。

import { getVapidPublicKey, subscribePush, unsubscribePush, ApiError } from './api';
import { hasPushScope } from './auth';

export function pushSupported(): boolean {
  return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
}

/** RFC 4648 base64url → Uint8Array。pushManager.subscribe が要る形。 */
function urlBase64ToUint8Array(base64url: string): Uint8Array {
  const padding = '='.repeat((4 - (base64url.length % 4)) % 4);
  const base64 = (base64url + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(base64);
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
}

// ブラウザが投げるのは DOMException のことが多く、実行環境によっては
// `instanceof Error` を通らない(name/message 自体は必ず持っている)。
// プロトタイプ鎖に頼らず、その場にある name/message をそのまま拾う。
function describeError(e: unknown): string {
  if (e && typeof e === 'object') {
    const name = 'name' in e ? String((e as { name?: unknown }).name) : '';
    const message = 'message' in e ? String((e as { message?: unknown }).message) : '';
    const joined = [name, message].filter((s) => s && s !== 'Error').join(': ');
    return joined || String(e);
  }
  return String(e);
}

export type PushState = 'unsupported' | 'denied' | 'subscribed' | 'unsubscribed';

export async function currentPushState(): Promise<PushState> {
  if (!pushSupported()) return 'unsupported';
  if (Notification.permission === 'denied') return 'denied';

  const reg = await navigator.serviceWorker.getRegistration();
  const sub = await reg?.pushManager.getSubscription();
  return sub ? 'subscribed' : 'unsubscribed';
}

/**
 * 通知を受け取り始める。返信(mention)だけ ── 種類はサーバ側の
 * direct_types が決める、こちらでは選ばせない(壊れやすい割に、
 * まだ選ぶほどの種類が無いので)。
 */
export async function enablePush(): Promise<PushState> {
  if (!pushSupported()) return 'unsupported';

  // push スコープが無いトークンなら、ここで断る ── 同期のチェックに
  // しているのが大事: サーバに問い合わせる版(await を挟む)は、
  // Notification.requestPermission() の**前**に非同期のすきまを作って
  // しまい、Firefox でそのあとの pushManager.subscribe() が
  // AbortError になる実害があった(ユーザー操作の文脈が、間の await で
  // 切れる)。requestPermission() は、押された直後に間を置かず呼ぶ。
  if (!hasPushScope()) {
    throw new Error('権限が足りません。一度サインアウトしてから、もう一度サインインしてください。');
  }

  const permission = await Notification.requestPermission();
  if (permission === 'denied') return 'denied';
  if (permission !== 'granted') return 'unsubscribed';

  const vapidKey = await getVapidPublicKey().catch(() => null);
  if (!vapidKey) {
    throw new Error('サーバから通知の鍵を取得できませんでした。しばらくしてからもう一度試してください。');
  }

  // register() はここで呼び直さない ── +layout.svelte が読み込み時に
  // 一度だけ登録している。ここでもう一度呼ぶと二重登録になり、Firefox
  // では新旧の登録がせめぎ合っているあいだに subscribe() が
  // AbortError になることがあった。
  let reg: ServiceWorkerRegistration;
  try {
    reg = await navigator.serviceWorker.ready;
  } catch {
    throw new Error('通知の仕組み(service worker)の準備ができませんでした。');
  }

  let sub: PushSubscription;
  try {
    // 前に別の鍵で購読していたことがあると、ブラウザは同じ端末で
    // 二重に持てず「購読を取得できない」エラーになる ── 一度解除して
    // から、いまの鍵で作り直す。解除してすぐ作り直すと、ブラウザの
    // push サービス側の後片付けが間に合わず AbortError になることが
    // あるので、一呼吸おく。
    const existing = await reg.pushManager.getSubscription();
    if (existing) {
      await existing.unsubscribe();
      await new Promise((r) => setTimeout(r, 300));
    }

    sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(vapidKey) as BufferSource
    });
  } catch (e) {
    const detail = describeError(e);
    // iOS Safari は、ホーム画面に追加してアプリとして開いたときしか
    // push を扱えない ── タブのまま押すと、ここに来る。
    if (detail.includes('NotSupportedError')) {
      throw new Error(
        'このブラウザのタブでは通知を使えません。ホーム画面に追加してから、そのアイコンで開いて試してください。'
      );
    }
    // Google/Mozilla の push サービスへの通信自体がブロックされている
    // ときによく出る(広告/プライバシー系の拡張機能、企業ネットワークの
    // ファイアウォールなど) ── ブラウザ内部の一般的な失敗メッセージ
    // (Registration failed など)しか付かないことが多いので、原因の
    // 見当を添える。
    if (detail.includes('AbortError')) {
      throw new Error(
        '購読が途中で止まりました。広告ブロック等の拡張機能を切るか、別のネットワークで試してください。'
      );
    }
    throw new Error(`ブラウザでの購読に失敗しました(${detail})。`);
  }

  try {
    await subscribePush(sub.toJSON() as PushSubscriptionJSON, { mention: true });
  } catch (e) {
    if (e instanceof ApiError && e.status === 403) {
      throw new Error('権限が足りません。一度サインアウトしてから、もう一度サインインしてください。');
    }
    throw new Error('サーバへの登録に失敗しました。時間をおいて、もう一度試してください。');
  }

  return 'subscribed';
}

export async function disablePush(): Promise<PushState> {
  if (!pushSupported()) return 'unsupported';

  const reg = await navigator.serviceWorker.getRegistration();
  const sub = await reg?.pushManager.getSubscription();
  if (sub) await sub.unsubscribe();

  try {
    await unsubscribePush();
  } catch {
    // ブラウザ側は解除できたので、サーバの行が残っても実害は小さい
    // (次に送ろうとしたときにエラーで気づける)。UI は先に進める。
  }

  return 'unsubscribed';
}
