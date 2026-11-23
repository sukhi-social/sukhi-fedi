// SPDX-License-Identifier: AGPL-3.0-or-later
// OAuth 認可コード + PKCE(S256)。この頁は静的で秘密を持てないので、client_secret は使わない。
// 行きに verifier と state を sessionStorage に置き、戻ったらコードを verifier と引き換える。

import { token } from './api.js';

const env = import.meta.env ?? {};
const base = () => (env.VITE_API_BASE ?? '').replace(/\/$/, '');
const SCOPE = 'admin:read admin:write';
const K = { verifier: 'gov.verifier', state: 'gov.state' };

const b64url = (bytes) => btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');

// 32 バイトの乱数 → 43 文字(RFC 7636 の 43〜128)
export const randomString = () => b64url(crypto.getRandomValues(new Uint8Array(32)));

export async function challengeOf(verifier) {
  return b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
}

// 戻り先は、この頁のトップ(登録した redirect_uri と、一字も違わないこと)。
export const redirectUri = () => location.origin + '/';

export function authorizeUrl({ clientId, challenge, state, redirect, scope = SCOPE }) {
  const q = new URLSearchParams({
    response_type: 'code',
    client_id: clientId,
    redirect_uri: redirect,
    scope,
    state,
    code_challenge: challenge,
    code_challenge_method: 'S256'
  });
  return `${base()}/oauth/authorize?${q}`;
}

export async function begin() {
  const verifier = randomString();
  const state = randomString();
  sessionStorage.setItem(K.verifier, verifier);
  sessionStorage.setItem(K.state, state);
  location.assign(authorizeUrl({ clientId: env.VITE_CLIENT_ID ?? '', challenge: await challengeOf(verifier), state, redirect: redirectUri() }));
}

// 戻ってきたとき(?code=…&state=…)。トークンを置けたら true。URL からコードは消す。
// 戻りが無ければ null、あっても通らなければ false(理由は error に)。
export async function finish(search = location.search, fetcher = fetch) {
  const q = new URLSearchParams(search);
  const code = q.get('code');
  const state = q.get('state');
  if (!code && !q.get('error')) return null;
  const want = sessionStorage.getItem(K.state);
  const verifier = sessionStorage.getItem(K.verifier);
  sessionStorage.removeItem(K.state);
  sessionStorage.removeItem(K.verifier);
  history.replaceState(null, '', location.pathname + location.hash);
  if (!code || !want || !verifier || state !== want) return false;
  let res;
  try {
    res = await fetcher(`${base()}/oauth/token`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ grant_type: 'authorization_code', client_id: env.VITE_CLIENT_ID ?? '', code, redirect_uri: redirectUri(), code_verifier: verifier })
    });
  } catch {
    return false;
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.access_token) return false;
  token.set(data.access_token);
  return true;
}
