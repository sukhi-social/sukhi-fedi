// SPDX-License-Identifier: AGPL-3.0-or-later
// リクエスト一件ぶんの文脈(Ctx)と、ルーター、静的ファイル、gateway への通し道。
//
// 外の依存は持たない。Node の http と fetch と Web の Request(formData)だけ。

import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { Readable } from 'node:stream';
import { extname } from 'node:path';
import { config } from './config.ts';
import { locate, locateIn } from './assets.ts';
import { detectLocale, makeT, type Locale, type T } from './i18n.ts';
import { createSession, getSession, saveSession, type Session } from './session.ts';
import type { Account } from './types.ts';
import { SafeHtml } from './html.ts';

// ── 返事 ─────────────────────────────────────────────────────────
export type Reply = {
  status: number;
  headers: Record<string, string>;
  body: string;
};

export function ok(body: SafeHtml | string, status = 200, headers: Record<string, string> = {}): Reply {
  return {
    status,
    headers: { 'content-type': 'text/html; charset=utf-8', ...headers },
    body: String(body)
  };
}

export function redirect(to: string, status = 303): Reply {
  return { status, headers: { location: to }, body: '' };
}

export function empty(status = 204): Reply {
  return { status, headers: {}, body: '' };
}

// ── 文脈 ─────────────────────────────────────────────────────────
export type Ctx = {
  req: IncomingMessage;
  url: URL;
  method: string;
  params: Record<string, string>;
  locale: Locale;
  t: T;
  // Unpoly からの要求か。一部の頁だけ(断片)を返してよいかの目安。
  isUp: boolean;
  // Unpoly が要求してきたターゲット(X-Up-Target)。
  upTarget?: string;
  // Unpoly のレイヤーモード(root, modal, drawer など)。
  upMode?: string;
  session: Session | undefined;
  // 返事に添える Set-Cookie。
  cookies: string[];
  // セッションを(なければ作って)返す。ログインや flash のように、状態を置く道で使う。
  sess(): Session;
  // 入っている人。トークンがなければ null。取れたらセッションにひかえる。
  me(): Promise<Account | null>;
  form(): Promise<FormData>;
  flash(kind: 'notice' | 'error', text: string): void;
  takeFlash(): Session['flash'];
  setCookie(name: string, value: string, opts?: { maxAge?: number; httpOnly?: boolean }): void;
};

const YEAR = 60 * 60 * 24 * 365;

function parseCookies(header: string | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  for (const part of (header ?? '').split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

export class Unauthorized extends Error {
  constructor() {
    super('unauthorized');
  }
}

export class NotFound extends Error {
  constructor() {
    super('not_found');
  }
}

async function makeCtx(req: IncomingMessage, params: Record<string, string>): Promise<Ctx> {
  const url = new URL(req.url ?? '/', config.publicOrigin);
  const cookies = parseCookies(req.headers.cookie);
  let session = getSession(cookies.sukhi_sid);
  const locale = detectLocale(cookies.sukhi_locale, session?.me?.source?.language, req.headers['accept-language']);
  const out: string[] = [];

  // dev のときだけ(SUKHI_DEV_TOKEN)。入った状態から始める。mock の gateway で、画面を見るため。
  if (config.devToken && !session?.token) {
    session ??= createSession();
    session.token = { access_token: config.devToken, scope: config.scopes, created_at: 0 };
    saveSession(session);
    out.push(`sukhi_sid=${encodeURIComponent(session.id)}; Path=/; Max-Age=${YEAR}; SameSite=Lax; HttpOnly`);
  }

  const ctx: Ctx = {
    req,
    url,
    method: req.method ?? 'GET',
    params,
    locale,
    t: makeT(locale),
    isUp: 'x-up-version' in req.headers,
    upTarget: typeof req.headers['x-up-target'] === 'string' ? req.headers['x-up-target'] : undefined,
    upMode: typeof req.headers['x-up-mode'] === 'string' ? req.headers['x-up-mode'] : undefined,
    session,
    cookies: out,
    sess() {
      if (!ctx.session) {
        ctx.session = createSession();
        ctx.setCookie('sukhi_sid', ctx.session.id, { httpOnly: true });
      }
      return ctx.session;
    },
    async me() {
      const s = ctx.session;
      if (!s?.token) return null;
      if (s.me) return s.me;
      const { gwJson } = await import('./gateway.ts');
      s.me = await gwJson<Account>(ctx, 'GET', '/api/v1/accounts/verify_credentials');
      saveSession(s);
      return s.me;
    },
    async form() {
      const type = req.headers['content-type'] ?? '';
      const web = new Request('http://localhost/', {
        method: 'POST',
        headers: { 'content-type': type },
        body: Readable.toWeb(req) as ReadableStream,
        // @ts-expect-error Node の fetch が要求する(stream を body にするとき)
        duplex: 'half'
      });
      return web.formData();
    },
    flash(kind, text) {
      const s = ctx.sess();
      s.flash = { kind, text };
      saveSession(s);
    },
    takeFlash() {
      const s = ctx.session;
      if (!s?.flash) return undefined;
      const f = s.flash;
      s.flash = undefined;
      saveSession(s);
      return f;
    },
    setCookie(name, value, opts = {}) {
      const parts = [
        `${name}=${encodeURIComponent(value)}`,
        'Path=/',
        `Max-Age=${opts.maxAge ?? YEAR}`,
        'SameSite=Lax'
      ];
      if (opts.httpOnly) parts.push('HttpOnly');
      if (config.secureCookie) parts.push('Secure');
      out.push(parts.join('; '));
    }
  };
  return ctx;
}

// ── ルーター ─────────────────────────────────────────────────────
type Handler = (ctx: Ctx) => Promise<Reply> | Reply;
type Route = { method: string; re: RegExp; keys: string[]; handler: Handler };

const routes: Route[] = [];

export function route(method: 'GET' | 'POST', pattern: string, handler: Handler): void {
  const keys: string[] = [];
  const src = pattern.replace(/[.+*?^${}()|[\]\\]/g, '\\$&').replace(/:([a-z_]+)/gi, (_m, k) => {
    keys.push(k);
    return '([^/]+)';
  });
  routes.push({ method, re: new RegExp(`^${src}/?$`), keys, handler });
}

// ── 静的ファイル ─────────────────────────────────────────────────
const MIME: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.webmanifest': 'application/manifest+json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.map': 'application/json'
};

// ルート直下に置く、ブラウザが決め打ちで取りに来るもの。
const ROOT_FILES = new Set([
  '/favicon.png',
  '/apple-touch-icon.png',
  '/icon-512.png',
  '/avatar-default.svg',
  '/manifest.webmanifest'
]);

async function serveStatic(req: IncomingMessage, res: ServerResponse, pathname: string): Promise<boolean> {
  const at = ROOT_FILES.has(pathname) ? locateIn(config.publicDir, pathname.slice(1), false) : locate(pathname);
  if (!at) return false;
  const { full, immutable } = at;
  const st = await stat(full).catch(() => null);
  if (!st?.isFile()) return false;

  const etag = `W/"${st.size.toString(16)}-${Math.floor(st.mtimeMs).toString(16)}"`;
  const headers: Record<string, string> = {
    'content-type': MIME[extname(full)] ?? 'application/octet-stream',
    'content-length': String(st.size),
    etag,
    'cache-control': immutable ? 'public, max-age=31536000, immutable' : 'no-cache'
  };
  if (req.headers['if-none-match'] === etag) {
    res.writeHead(304, headers);
    res.end();
    return true;
  }
  res.writeHead(200, headers);
  if (req.method === 'HEAD') res.end();
  else createReadStream(full).pipe(res);
  return true;
}

// ── gateway への通し道 ───────────────────────────────────────────
// gateway が自分で持っている入り口(OAuth、法的ページ、メディア、連合)は、そのまま通す。
// ここを通さないと、ブラウザは gateway に届かない(同じ origin の前に、この郵便局が立つため)。
const PROXY_PREFIXES = [
  '/oauth/',
  '/api/',
  '/.well-known/',
  '/nodeinfo',
  '/terms',
  '/privacy',
  '/static/',
  '/uploads/',
  '/proxy/',
  '/users/',
  '/inbox'
];

const HOP = new Set([
  'connection',
  'keep-alive',
  'transfer-encoding',
  'upgrade',
  'host',
  'content-length',
  'content-encoding'
]);

function isProxied(pathname: string): boolean {
  return PROXY_PREFIXES.some((p) => pathname === p.replace(/\/$/, '') || pathname.startsWith(p));
}

async function proxy(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) {
    if (HOP.has(k) || v === undefined) continue;
    headers.set(k, Array.isArray(v) ? v.join(', ') : v);
  }
  const host = req.headers.host ?? new URL(config.publicOrigin).host;
  headers.set('x-forwarded-host', host);
  headers.set('x-forwarded-proto', new URL(config.publicOrigin).protocol.replace(':', ''));

  const hasBody = req.method !== 'GET' && req.method !== 'HEAD';
  let upstream: Response;
  try {
    upstream = await fetch(config.gateway + (req.url ?? '/'), {
      method: req.method,
      headers,
      body: hasBody ? (Readable.toWeb(req) as ReadableStream) : undefined,
      // @ts-expect-error duplex は Node の fetch の拡張
      duplex: hasBody ? 'half' : undefined,
      redirect: 'manual'
    });
  } catch {
    res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('gateway に届きませんでした。');
    return;
  }

  const out: Record<string, string | string[]> = {};
  upstream.headers.forEach((v, k) => {
    if (HOP.has(k) || k === 'set-cookie') return;
    out[k] = v;
  });
  const cookies = upstream.headers.getSetCookie();
  if (cookies.length) out['set-cookie'] = cookies;
  // gateway の origin を指す戻り先は、この郵便局の origin に直す。
  const loc = upstream.headers.get('location');
  if (loc?.startsWith(config.gateway)) out.location = config.publicOrigin + loc.slice(config.gateway.length);

  res.writeHead(upstream.status, out);
  if (upstream.body && req.method !== 'HEAD') Readable.fromWeb(upstream.body as never).pipe(res);
  else res.end();
}

// ── 本体 ─────────────────────────────────────────────────────────
// POST は、同じ origin からだけ受ける。SameSite=Lax の cookie に加えての、二重の戸締まり。
function sameOrigin(req: IncomingMessage): boolean {
  const origin = req.headers.origin;
  if (origin) {
    try {
      return new URL(origin).host === req.headers.host;
    } catch {
      return false;
    }
  }
  const site = req.headers['sec-fetch-site'];
  return site === undefined || site === 'same-origin' || site === 'none';
}

type ErrorPage = (ctx: Ctx, status: number) => Reply;
let errorPage: ErrorPage = (_c, status) => ok(String(status), status);
export function setErrorPage(fn: ErrorPage): void {
  errorPage = fn;
}

export function serve(port: number): ReturnType<typeof createServer> {
  const server = createServer(async (req, res) => {
    const started = Date.now();
    const { pathname } = new URL(req.url ?? '/', 'http://localhost');
    let status = 500;

    try {
      if ((req.method === 'GET' || req.method === 'HEAD') && (await serveStatic(req, res, pathname))) {
        status = res.statusCode;
        return;
      }

      if (isProxied(pathname)) {
        await proxy(req, res);
        status = res.statusCode;
        return;
      }

      let matched: { route: Route; params: Record<string, string> } | undefined;
      let pathKnown = false;
      for (const r of routes) {
        const m = r.re.exec(pathname);
        if (!m) continue;
        pathKnown = true;
        if (r.method !== (req.method === 'HEAD' ? 'GET' : req.method)) continue;
        const params: Record<string, string> = {};
        r.keys.forEach((k, i) => (params[k] = decodeURIComponent(m[i + 1])));
        matched = { route: r, params };
        break;
      }

      const ctx = await makeCtx(req, matched?.params ?? {});
      let reply: Reply;

      if (!matched) {
        reply = errorPage(ctx, pathKnown ? 405 : 404);
      } else if (req.method === 'POST' && !sameOrigin(req)) {
        reply = errorPage(ctx, 403);
      } else {
        try {
          reply = await matched.route.handler(ctx);
        } catch (e) {
          if (e instanceof Unauthorized) {
            const s = ctx.session;
            if (s) {
              s.token = undefined;
              s.me = undefined;
              saveSession(s);
            }
            reply = redirect('/login?again=true');
          } else if (e instanceof NotFound) {
            reply = errorPage(ctx, 404);
          } else {
            console.error(`[error] ${req.method} ${pathname}`, e);
            reply = errorPage(ctx, 502);
          }
        }
      }

      status = reply.status;
      const headers: Record<string, string | string[]> = { ...reply.headers, vary: 'X-Up-Version, Cookie' };
      if (ctx.cookies.length) headers['set-cookie'] = ctx.cookies;
      headers['content-length'] = String(Buffer.byteLength(reply.body));
      if (reply.body && !headers['cache-control']) headers['cache-control'] = 'no-store';
      res.writeHead(reply.status, headers);
      res.end(req.method === 'HEAD' ? undefined : reply.body);
    } catch (e) {
      console.error('[fatal]', e);
      if (!res.headersSent) res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('error');
    } finally {
      if (process.env.QUIET !== '1') console.log(`${req.method} ${pathname} ${status} ${Date.now() - started}ms`);
    }
  });
  server.listen(port);
  return server;
}
