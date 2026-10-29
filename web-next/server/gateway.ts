// gateway(Elixir)の /api/v1 を、サーバから呼ぶ。
//
// SPA の api.ts の `req` と同じ約束を、サーバ側の言葉で:
//   ・トークンはセッションから付ける。ブラウザには、トークンは一度も渡らない
//   ・認証つき(auth: true)で 401 なら、refresh-token で一度だけ取り直して、一度だけ再送
//     それでも 401 なら、セッションは戻せない(Unauthorized → /login へ)
//   ・auth: 'optional' は、入っていればトークンを付けるが、401 でも終わらせない(公開の読み)
//   ・2xx でなければ、サーバの `error` を持った GatewayError を投げる

import { config } from './config.ts';
import { getClient } from './client.ts';
import { saveSession } from './session.ts';
import { Unauthorized, NotFound, type Ctx } from './http.ts';
import type { Page, TokenSet } from './types.ts';

export class GatewayError extends Error {
  status: number;
  details?: Record<string, string[]>;
  constructor(message: string, status: number, details?: Record<string, string[]>) {
    super(message);
    this.status = status;
    this.details = details;
  }
}

type Init = {
  auth?: boolean | 'optional';
  json?: unknown;
  form?: FormData;
  query?: Record<string, string | string[] | undefined>;
  notFound?: boolean; // 404 を NotFound にする(頁の 404 にしたいとき)
};

// 同時に飛んだ 401 が、それぞれ refresh を叩かないように、セッションごとに一本へ束ねる。
// refresh token は使うと rotate するので、並行に叩くと片方が負ける。
const refreshing = new Map<string, Promise<TokenSet | null>>();

async function refresh(ctx: Ctx): Promise<TokenSet | null> {
  const s = ctx.session;
  if (!s?.token?.refresh_token) return null;
  const inflight = refreshing.get(s.id);
  if (inflight) return inflight;

  const p = (async () => {
    try {
      const client = await getClient();
      const res = await fetch(`${config.gateway}/oauth/token`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          grant_type: 'refresh_token',
          refresh_token: s.token!.refresh_token,
          client_id: client.client_id,
          client_secret: client.client_secret
        })
      });
      if (!res.ok) return null;
      const t = (await res.json()) as TokenSet;
      s.token = t;
      saveSession(s);
      return t;
    } catch {
      return null;
    }
  })().finally(() => refreshing.delete(s.id));
  refreshing.set(s.id, p);
  return p;
}

export async function gw(ctx: Ctx, method: string, path: string, init: Init = {}): Promise<Response> {
  const auth = init.auth ?? true;

  let url = config.gateway + path;
  if (init.query) {
    const qs = new URLSearchParams();
    for (const [k, v] of Object.entries(init.query)) {
      if (v === undefined) continue;
      for (const one of Array.isArray(v) ? v : [v]) qs.append(k, one);
    }
    const s = qs.toString();
    if (s) url += (path.includes('?') ? '&' : '?') + s;
  }

  const send = (anonymous = false) => {
    const headers: Record<string, string> = { accept: 'application/json' };
    let body: BodyInit | undefined;
    if (init.json !== undefined) {
      headers['content-type'] = 'application/json';
      body = JSON.stringify(init.json);
    } else if (init.form) {
      body = init.form;
    }
    const token = ctx.session?.token;
    if (auth !== false && token && !anonymous) headers.authorization = `Bearer ${token.access_token}`;
    return fetch(url, { method, headers, body });
  };

  if (auth === true && !ctx.session?.token) throw new Unauthorized();

  let res = await send();

  if (auth === true && res.status === 401) {
    if (await refresh(ctx)) res = await send();
    if (res.status === 401) throw new Unauthorized();
  }

  // 'optional' は、入っていれば見える範囲が広がる、というだけの読み。トークンが古くて 401 でも、
  // 取り直してだめなら、匿名で読み直す(公開のものまで読めなくならないように)。終わらせはしない。
  if (auth === 'optional' && res.status === 401 && ctx.session?.token) {
    if (await refresh(ctx)) res = await send();
    if (res.status === 401) res = await send(true);
  }

  if (init.notFound && res.status === 404) throw new NotFound();
  if (!res.ok) {
    const err = (await res.json().catch(() => ({}))) as { error?: string; details?: Record<string, string[]> };
    throw new GatewayError(err.error ?? `gateway_${res.status}`, res.status, err.details);
  }
  return res;
}

export async function gwJson<T>(ctx: Ctx, method: string, path: string, init: Init = {}): Promise<T> {
  const res = await gw(ctx, method, path, init);
  if (res.status === 204) return null as T;
  return (await res.json()) as T;
}

// Link: <…max_id=N>; rel="next" から、次のページの印(max_id)を読む。
function nextMaxId(link: string | null): string | null {
  if (!link) return null;
  for (const part of link.split(',')) {
    const m = part.match(/<([^>]+)>;\s*rel="next"/);
    if (!m) continue;
    try {
      return new URL(m[1], config.gateway).searchParams.get('max_id');
    } catch {
      return null;
    }
  }
  return null;
}

export async function gwPage<T>(ctx: Ctx, path: string, init: Init = {}): Promise<Page<T>> {
  const res = await gw(ctx, 'GET', path, init);
  const items = (await res.json()) as T[];
  // 0 件なら、Link が次を匂わせていても、ここが終わり。
  return { items, nextMaxId: items.length === 0 ? null : nextMaxId(res.headers.get('link')) };
}

// gateway が session_token などの cookie を立てて返したとき、ブラウザへそのまま渡す。
// (/oauth/authorize は、ブラウザの cookie を読むため。同じ origin の前にこの郵便局が立っている。)
export function forwardCookies(ctx: Ctx, res: Response): void {
  for (const c of res.headers.getSetCookie()) ctx.cookies.push(c);
}
