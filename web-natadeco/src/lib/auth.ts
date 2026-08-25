// OAuth クライアント + トークン保存。sukhi-fedi 本体の web と同じ
// エンドポイント・同じ localStorage の鍵(sf.client / sf.token)を使う
// ── api.ts がすでに sf.token を読んでいるので、ここで作る側になる。
//
// マルチアカウント・パスキー・アプリ2FA は持たない(natadeco には
// まだ要らない)。要るときに sukhi-fedi/web/src/lib/auth.ts から
// 同じ形で足せる。

import { browser } from '$app/environment';

// v2: push スコープを足したので、古い(read write だけの)登録済み
// アプリを使い続けさせない ── キーを変えて再登録を強制する。
const CLIENT_KEY = 'sf.client.v2';
const TOKEN_KEY = 'sf.token';
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

export function isLoggedIn(): boolean {
  return !!loadToken();
}

/**
 * いまのトークンに push スコープがあるか。**同期**で見る ── サーバに
 * 問い合わせて確かめる版は、Notification.requestPermission() の前に
 * await を挟んでしまい、ユーザー操作の文脈が切れて Firefox で
 * pushManager.subscribe() が AbortError になる、という実害があった。
 * 保存済みトークンの scope 文字列をその場で見るだけなら、間に何も挟まない。
 */
export function hasPushScope(): boolean {
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

// ── ログイン ─────────────────────────────────────────────────────────
//
// 一段目(パスワード or メールコード)は cookie を立てるだけ。そこから
// OAuth の Authorization Code フローで、はじめて sf.token になる。

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

export async function startLogin(): Promise<void> {
  const client = await loadOrRegisterClient();
  const state = crypto.randomUUID();
  localStorage.setItem(STATE_KEY, state);

  const params = new URLSearchParams({
    response_type: 'code',
    client_id: client.client_id,
    redirect_uri: client.redirect_uri,
    scope: SCOPES,
    state
  });
  window.location.assign(`/oauth/authorize?${params.toString()}`);
}

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

// RFC 7009。失敗しても、手元のトークンは必ず消す ── サインアウトは
// 常に終わる。
export async function signOutServer(): Promise<void> {
  if (!browser) return;
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
