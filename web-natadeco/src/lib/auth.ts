// ログインの道。一段目(合言葉・メールのコード・パスキー)が通れば
// httpOnly の session cookie が立って、それで終わり ── API はその cookie
// を読んでいる人として見る(api.ts)。OAuth の往復(/oauth/authorize →
// /app/callback → sf.token)は、もう始めない。`completeLogin` は、その途中に
// いた人が戻ってきたときのために残してある。
//
// マルチアカウント・アプリ2FA は持たない(natadeco にはまだ要らない)。
// 要るときに sukhi-fedi/web/src/lib/auth.ts から同じ形で足せる。
// パスキーは、この下のほうに在る ── 合言葉を持たない人が多い場所なので、
// 毎回メールのコードを待たなくていい道を、いちばん最初に足した。

import { browser } from '$app/environment';
import { TOKEN_KEY, cookieSignedIn } from '$lib/api';

// v2: push スコープを足したので、古い(read write だけの)登録済み
// アプリを使い続けさせない ── キーを変えて再登録を強制する。
const CLIENT_KEY = 'sf.client.v2';
const STATE_KEY = 'sf.state';

// push が無いと `POST /api/v1/push/subscription` が scope 不足で断られる
// ── 通知を ON にできない、で気づいた。
const SCOPES = 'read write push';

export type ClientCreds = {
  client_id: string;
  client_secret: string;
  redirect_uri: string;
};

export type TokenSet = {
  access_token: string;
  refresh_token?: string | null;
  scope: string;
  created_at: number;
};

export function loadToken(): TokenSet | null {
  if (!browser) return null;
  const raw = localStorage.getItem(TOKEN_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as TokenSet;
  } catch {
    return null;
  }
}

function saveToken(t: TokenSet): void {
  if (!browser) return;
  localStorage.setItem(TOKEN_KEY, JSON.stringify(t));
}

export function clearToken(): void {
  if (!browser) return;
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(CLIENT_KEY);
}

/**
 * push スコープがあるか。**同期**で見る ── サーバに問い合わせて確かめる
 * 版は、Notification.requestPermission() の前に await を挟んでしまい、
 * ユーザー操作の文脈が切れて Firefox で pushManager.subscribe() が
 * AbortError になる、という実害があった。
 * cookie で入っている人は、サーバがいつも `read write push` を与える。
 * 古いトークンの人は、その scope 文字列をその場で見る。
 */
export function hasPushScope(): boolean {
  if (cookieSignedIn()) return true;
  const t = loadToken();
  return !!t && t.scope.split(/\s+/).includes('push');
}

async function loadOrRegisterClient(): Promise<ClientCreds> {
  if (!browser) throw new Error('no browser');
  const raw = localStorage.getItem(CLIENT_KEY);
  if (raw) {
    try {
      return JSON.parse(raw) as ClientCreds;
    } catch {
      /* fall through — re-register */
    }
  }

  const redirect_uri = `${window.location.origin}/app/callback`;
  const res = await fetch('/api/v1/apps', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      client_name: 'natadeco web',
      redirect_uris: redirect_uri,
      scopes: SCOPES,
      website: window.location.origin
    })
  });
  if (!res.ok) throw new Error(`app registration failed: ${res.status}`);

  const body = await res.json();
  const creds: ClientCreds = {
    client_id: body.client_id,
    client_secret: body.client_secret,
    redirect_uri
  };
  localStorage.setItem(CLIENT_KEY, JSON.stringify(creds));
  return creds;
}

// ── 関所(/check)へ渡すもの ───────────────────────────────────────────
//
// Anubis が CHALLENGE するのは `/check` の一本だけ。店先(/login /signup)
// は素通しで、そこで打ったものは sessionStorage に置いて関所へ渡す ──
// URL には載せない(メールアドレスも合言葉も、履歴に残る場所ではない)。
//
// **API を先に叩いて後で PoW、にはしない。** メールの送信もアカウントの
// 作成も、関所を通れた人の手でだけ起こる ── 逆にすると、PoW を通れない
// 人のアカウントが先に出来てしまう。

const DRAFT_KEY = 'nd.signup_draft';
const LOGIN_EMAIL_KEY = 'nd.login_email';

// email_proof は /signup/email/confirm が返す「このメールボックスを開けた」
// 証明(20分)。秘密ではないので、作成が転んだときのために draft に残す
// ── 打ち直しが要るのは合言葉だけになる。
export type SignupDraft = {
  username: string;
  email: string;
  password?: string;
  email_proof?: string;
};

export function saveSignupDraft(d: SignupDraft): void {
  if (!browser) return;
  sessionStorage.setItem(DRAFT_KEY, JSON.stringify(d));
}

export function loadSignupDraft(): SignupDraft | null {
  if (!browser) return null;
  const raw = sessionStorage.getItem(DRAFT_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as SignupDraft;
  } catch {
    return null;
  }
}

// 合言葉だけ落とした draft で上書きする。/check が signup() を呼ぶ直前に
// 必ず通す ── 成功でも失敗でも、そこから先の sessionStorage に合言葉は
// 無い。
export function clearSignupPassword(): void {
  if (!browser) return;
  const d = loadSignupDraft();
  if (!d) return;
  const { password: _password, ...rest } = d;
  sessionStorage.setItem(DRAFT_KEY, JSON.stringify(rest));
}

export function clearSignupDraft(): void {
  if (!browser) return;
  sessionStorage.removeItem(DRAFT_KEY);
}

export function saveLoginEmail(email: string): void {
  if (!browser) return;
  sessionStorage.setItem(LOGIN_EMAIL_KEY, email);
}

export function loadLoginEmail(): string | null {
  if (!browser) return null;
  return sessionStorage.getItem(LOGIN_EMAIL_KEY);
}

export function clearLoginEmail(): void {
  if (!browser) return;
  sessionStorage.removeItem(LOGIN_EMAIL_KEY);
}

// 関所へ入る。**必ずフルリロード**で ── SPA のナビだとサーバに request が
// 行かないので、Anubis がそこに居ることにならない。
export function goToCheck(intent: 'login' | 'signup' | 'login-email'): void {
  window.location.assign(`/check?intent=${intent}`);
}

// ── 加入 ─────────────────────────────────────────────────────────────
//
// メールボックスを開けた証明(email_proof)と引き換えに、その場で
// トークンがもらえる ── OAuth のリダイレクトを挟まない、加入だけの
// 近道。招待コードは送らない(natadeco は不要な設定なので)。

export async function requestSignupEmailCode(email: string): Promise<void> {
  const res = await fetch('/signup/email/request', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email })
  });
  if (res.ok) return;
  const body = await res.json().catch(() => ({}));
  throw new Error((body as { error?: string })?.error ?? `signup_email_failed_${res.status}`);
}

export async function confirmSignupEmailCode(email: string, code: string): Promise<string> {
  const res = await fetch('/signup/email/confirm', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, code })
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error((body as { error?: string })?.error ?? `signup_email_failed_${res.status}`);
  }
  return (body as { email_proof: string }).email_proof;
}

export async function signup(
  username: string,
  emailProof: string,
  password?: string
): Promise<TokenSet> {
  const client = await loadOrRegisterClient();

  const ccRes = await fetch('/oauth/token', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'client_credentials',
      client_id: client.client_id,
      client_secret: client.client_secret,
      scope: SCOPES
    })
  });
  if (!ccRes.ok) throw new Error(`client_credentials failed: ${ccRes.status}`);
  const appToken = (await ccRes.json()) as TokenSet;

  const res = await fetch('/api/v1/accounts', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${appToken.access_token}`
    },
    body: JSON.stringify({
      username,
      email_proof: emailProof,
      ...(password ? { password } : {})
    })
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(body?.error ?? `signup_failed_${res.status}`);
    (err as Error & { details?: Record<string, string[]> }).details = body?.details;
    throw err;
  }

  saveToken(body as TokenSet);
  return body as TokenSet;
}

// 加入したあと、同じ email_proof を session cookie に替える。
// パスキーの登録口(/settings/passkeys/*)は cookie 専用なので、これを
// 通しておかないと「加入してすぐ鍵にする」ができない ── メールを開けた
// 証明は、合言葉を入れなおすのと同じ重さ、というのがサーバ側の決め。
// 立たなかったら false ── 呼び元は、そのときパスキーのおさそいを
// 出さずに黙って先へ進む(加入を止める理由には、ならないので)。
export async function startSignupSession(emailProof: string): Promise<boolean> {
  try {
    const res = await fetch('/signup/session', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ email_proof: emailProof })
    });
    return res.ok;
  } catch {
    return false;
  }
}

// ── ログイン ─────────────────────────────────────────────────────────
//
// 一段目(パスワード or メールコード or パスキー)が cookie を立てる。
// それでログインは終わり ── 呼ぶ側は、行きたかった場所へ進むだけ。

export type FirstFactorResult = { ok: true };

export async function loginWithPassword(username: string, password: string): Promise<void> {
  const res = await fetch('/login', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ username, password })
  });
  if (res.status === 401) throw new Error('invalid');
  if (!res.ok) throw new Error(`login_failed_${res.status}`);
}

export async function requestEmailLoginCode(email: string): Promise<void> {
  const res = await fetch('/login/email/request', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ email })
  });
  if (res.ok) return;
  const body = await res.json().catch(() => ({}));
  throw new Error(body?.error ?? `email_request_failed_${res.status}`);
}

export async function loginWithEmailCode(email: string, code: string): Promise<void> {
  const res = await fetch('/login/email', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ email, code })
  });
  if (res.ok) return;
  const body = await res.json().catch(() => ({}));
  throw new Error(body?.error ?? `email_login_failed_${res.status}`);
}

// パスキーで入る。options → ブラウザの認証器 → submit まで一息に。
// 通れば cookie が立つ。二段目は無い ── 認証器の指紋や顔が、その役を
// している。
export async function loginWithPasskey(): Promise<void> {
  const { getPasskeyAssertion } = await import('./webauthn');

  const optRes = await fetch('/login/passkey/options', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: '{}'
  });
  if (!optRes.ok) throw new Error('passkey');
  const { ref, publicKey } = await optRes.json();

  const assertion = await getPasskeyAssertion(publicKey);

  const res = await fetch('/login/passkey', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ ref, ...assertion })
  });
  if (!res.ok) throw new Error('passkey');
}

// OAuth の往復の戻り(/app/callback)。始める側はもう無いが、この変更の
// 前に /oauth/authorize へ出ていた人が戻ってきたら、まだここで受ける。
export async function completeLogin(code: string, state: string): Promise<TokenSet> {
  const expected = localStorage.getItem(STATE_KEY);
  if (!expected || expected !== state) throw new Error('state mismatch');
  localStorage.removeItem(STATE_KEY);

  const client = await loadOrRegisterClient();
  const res = await fetch('/oauth/token', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'authorization_code',
      code,
      client_id: client.client_id,
      client_secret: client.client_secret,
      redirect_uri: client.redirect_uri
    })
  });
  if (!res.ok) throw new Error(`token exchange failed: ${res.status}`);

  const t = (await res.json()) as TokenSet;
  saveToken(t);
  return t;
}

// 加入のさいご、任意のひとこと。断られても・失敗しても先へは進める
// ── ここで足踏みさせる意味は無いので。
export async function setWarmthNote(token: string, note: string): Promise<void> {
  await fetch('/api/v1/accounts/update_credentials', {
    method: 'PATCH',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${token}`
    },
    body: JSON.stringify({ note })
  }).catch(() => {});
}

// cookie を落とす(POST /logout。302 で返るが、辿らない)。古いトークンを
// 持っている人は、それも RFC 7009 で戻す。どれが失敗しても手元のものは
// 必ず消す ── サインアウトは常に終わる。
export async function signOutServer(): Promise<void> {
  if (!browser) return;
  await fetch('/logout', { method: 'POST', credentials: 'same-origin', redirect: 'manual' }).catch(
    () => {}
  );
  const t = loadToken();
  const raw = localStorage.getItem(CLIENT_KEY);
  if (t && raw) {
    try {
      const c = JSON.parse(raw) as ClientCreds;
      await fetch('/oauth/revoke', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          token: t.access_token,
          client_id: c.client_id,
          client_secret: c.client_secret
        })
      });
    } catch {
      /* best-effort */
    }
  }
  clearToken();
}

// ── パスキーの管理(/settings/security) ───────────────────────────────
//
// 変更系は session cookie 専用。bearer は第三者アプリにも渡るので、
// ログインの要素には触らせない、というサーバ側の決め。/auth/state だけ
// bearer でも読めて、`manageable` が「いま cookie で触れるか」を返す。

export type AuthState = {
  // false = cookie が無い(切れた)。変更系を呼ぶ前に /login を通りなおす。
  manageable: boolean;
  acct: string;
  email: string | null;
  email_verified: boolean;
  // false = 合言葉なし(natadeco では、こちらが標準)。鍵を外すときの
  // 本人確認は、合言葉のかわりにメールへ届く 6 桁になる。
  has_password: boolean;
  totp_enabled: boolean;
  totp_pending: boolean;
  passkeys: Passkey[];
};

export type Passkey = {
  id: number;
  nickname: string | null;
  created_at: string;
  last_used_at: string | null;
};

// 鍵を外すときの本人確認。合言葉を持つ人は password、持たない人は
// requestReauthCode() で届く 6 桁を reauth_code に。
export type Reauth = { password?: string; reauth_code?: string };

async function settingsPost(path: string, body: unknown): Promise<unknown> {
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify(body ?? {})
  });
  const parsed = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error((parsed as { error?: string })?.error ?? `failed_${res.status}`);
  }
  return parsed;
}

export async function fetchAuthState(): Promise<AuthState | null> {
  const t = loadToken();
  const res = await fetch('/auth/state', {
    credentials: 'same-origin',
    headers: t ? { authorization: `Bearer ${t.access_token}` } : {}
  });
  if (res.status === 401) return null;
  if (!res.ok) throw new Error(`auth_state_failed_${res.status}`);
  return (await res.json()) as AuthState;
}

// 本人確認のコードを、登録ずみの確認済みメールへ送る。
export async function requestReauthCode(): Promise<void> {
  await settingsPost('/settings/reauth/request', {});
}

// パスキー登録: options → 認証器 → 登録、まで。
export async function registerPasskey(nickname: string): Promise<void> {
  const { createPasskey } = await import('./webauthn');

  const { ref, publicKey } = (await settingsPost('/settings/passkeys/options', {})) as {
    ref: string;
    publicKey: Parameters<typeof createPasskey>[0];
  };

  const payload = await createPasskey(publicKey);
  await settingsPost('/settings/passkeys', { ref, nickname, ...payload });
}

// 名前だけ変える。鍵そのものは触らないので、本人確認は要らない。
export async function renamePasskey(id: number, nickname: string): Promise<void> {
  await settingsPost(`/settings/passkeys/${id}/rename`, { nickname });
}

export async function deletePasskey(id: number, reauth: Reauth): Promise<void> {
  await settingsPost(`/settings/passkeys/${id}/delete`, reauth);
}
