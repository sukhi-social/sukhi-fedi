// natadeco の API 一枚。読むのは誰でも、書くのはログインしている人。
//
// トークンは sukhi-fedi の web が置いた `sf.token` をそのまま読む ──
// 同じ origin に並べて置くので、入口（ログイン）は一つでいい。natadeco
// のためにもう一本、認証の道を作らない。

import { getLang } from '$lib/i18n.svelte';

export type Deco = {
  id: number;
  slug: string;
  name: string;
  name_i18n: Record<string, string>;
  description: string | null;
  description_i18n: Record<string, string>;
  // この板は、ふつうどちらで書くか。一件ごとには書く人が選べる（既定であって錠ではない）。
  local_only: boolean;
  // 読まれかた。'thread' は題つき・bump、'talk' は平ら・書かれた順。
  kind: 'thread' | 'talk';
  // 表札 ── 外から見つけられる場所として立っているか。false なら
  // `{slug}-deco@domain` は引けない（書いた一件は、選べば外に出る）。
  has_actor: boolean;
  post_count: number;
  created_at: string;
};

export type Author = {
  username: string;
  acct: string;
  display_name: string;
  avatar_url: string | null;
};

export type Emoji = {
  shortcode: string;
  url: string;
  static_url?: string | null;
};

// 絵文字リアクション。`url` はカスタム絵文字のときだけ入る（unicode は null）。
// 並びはサーバが決める（多い順→絵文字順）── こちらでは並び替えない。
export type Reaction = {
  name: string;
  count: number;
  me: boolean;
  url?: string | null;
  static_url?: string | null;
};

export type Post = {
  id: number;
  deco_id: number;
  title: string | null;
  title_i18n: Record<string, string>;
  // 生の Markdown ── 直すときの下書き欄に、いま書いてあるものをそのまま出すため。
  content: string;
  content_i18n: Record<string, string>;
  content_html: string;
  content_html_i18n: Record<string, string>;
  author: Author;
  created_at: string;
  reply_count: number;
  local_only: boolean;
  emojis: Emoji[];
  reactions: Reaction[];
  replies?: Post[];
  // 話す板の流れでだけ入る。返信が「誰に向けた言葉か」を、一段だけ。
  // 手元に無い親（連合越しなど）は null。
  parent?: { id: number; author: Author; excerpt: string } | null;
};

export type Visibility = 'public' | 'local';

/**
 * 主言語(ja)＋上乗せ(例: ko)から、いまの表示言語に合うほうを返す。
 * 訳が無ければ主言語のまま ── 「無ければ隠す」ではなく「無ければ元」。
 */
export function localized(primary: string | null, i18n: Record<string, string> | undefined): string {
  const lang = getLang();
  if (lang === 'ja') return primary ?? '';
  return i18n?.[lang] || primary || '';
}

export type CurrentAccount = {
  username: string;
  acct: string;
  display_name: string;
  note: string;
  avatar_url: string | null;
  isAdmin: boolean;
};

const TOKEN_KEY = 'sf.token';

export function token(): string | null {
  if (typeof localStorage === 'undefined') return null;
  const raw = localStorage.getItem(TOKEN_KEY);
  if (!raw) return null;
  try {
    return (JSON.parse(raw) as { access_token?: string }).access_token ?? null;
  } catch {
    return null;
  }
}

export function signedIn(): boolean {
  return token() !== null;
}

export class ApiError extends Error {
  constructor(
    public status: number,
    public detail: unknown
  ) {
    super(`natadeco api ${status}`);
  }
}

async function req<T>(method: string, path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = {};
  const t = token();
  if (t) headers.authorization = `Bearer ${t}`;
  if (body !== undefined) headers['content-type'] = 'application/json';

  const res = await fetch(path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body)
  });

  const text = await res.text();
  const parsed = text ? JSON.parse(text) : null;
  if (!res.ok) throw new ApiError(res.status, parsed);
  return parsed as T;
}

export const listDecos = () => req<Deco[]>('GET', '/api/v1/deco');
export const getDeco = (slug: string) => req<Deco>('GET', `/api/v1/deco/${encodeURIComponent(slug)}`);

export function listPosts(slug: string, beforeId?: number) {
  const q = beforeId ? `?before_id=${beforeId}` : '';
  return req<Post[]>('GET', `/api/v1/deco/${encodeURIComponent(slug)}/posts${q}`);
}

export const getPost = (id: number | string) => req<Post>('GET', `/api/v1/deco/posts/${id}`);

/**
 * 話す板の流れ。平らに、書かれた順（新しい順）。
 *
 * `since` は「ここまでで終わり」の下限。読む人の真夜中を渡すので、
 * 「今日」の境目を決めるのは読む人の時計 ── サーバは今日を知らない。
 */
export function listFlow(slug: string, opts: { beforeId?: number; since?: Date } = {}) {
  const q = new URLSearchParams();
  if (opts.beforeId) q.set('before_id', String(opts.beforeId));
  if (opts.since) q.set('since', opts.since.toISOString());
  const qs = q.toString();
  return req<Post[]>('GET', `/api/v1/deco/${encodeURIComponent(slug)}/flow${qs ? `?${qs}` : ''}`);
}

/** 読む人の時計での、今日のはじまり。 */
export function startOfToday(): Date {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d;
}

export const createPost = (
  slug: string,
  body: {
    title?: string;
    status: string;
    title_i18n?: Record<string, string>;
    content_i18n?: Record<string, string>;
    visibility?: Visibility;
  }
) => req<Post>('POST', `/api/v1/deco/${encodeURIComponent(slug)}/posts`, body);

// リアクションは sukhi 本体の口をそのまま使う（deco 専用の道を作らない）。
// 返るのは Mastodon の Status なので、こちらが要るのは `reactions` だけ。
const reactPath = (id: number | string, emoji: string) =>
  `/api/v1/sukhi/statuses/${id}/react/${encodeURIComponent(emoji)}`;

export const react = (id: number | string, emoji: string) =>
  req<{ reactions: Reaction[] }>('PUT', reactPath(id, emoji));

export const unreact = (id: number | string, emoji: string) =>
  req<{ reactions: Reaction[] }>('DELETE', reactPath(id, emoji));

export const createReply = (
  id: number | string,
  body: { status: string; content_i18n?: Record<string, string>; visibility?: Visibility }
) => req<Post>('POST', `/api/v1/deco/posts/${id}/replies`, body);

/** 自分の投稿・レスを直す。渡した欄だけ差し替わる。 */
export const updatePost = (
  id: number | string,
  body: { title?: string; status?: string; title_i18n?: Record<string, string>; content_i18n?: Record<string, string> }
) => req<Post>('PATCH', `/api/v1/deco/posts/${id}`, body);

/** 自分の投稿・レスを消す。取り消せない。 */
export const deletePost = (id: number | string) => req<null>('DELETE', `/api/v1/deco/posts/${id}`);

/** push 通知に要る、サーバの VAPID 公開鍵。無ければ push は未設定。 */
export async function getVapidPublicKey(): Promise<string | null> {
  const body = await req<{ configuration?: { vapid?: { public_key?: string | null } } }>(
    'GET',
    '/api/v2/instance'
  );
  return body.configuration?.vapid?.public_key ?? null;
}

/** ブラウザの PushSubscription を、サーバに登録する。 */
export const subscribePush = (subscription: PushSubscriptionJSON, alerts: Record<string, boolean>) =>
  req<{ id: string; endpoint: string; alerts: Record<string, boolean> }>(
    'POST',
    '/api/v1/push/subscription',
    { subscription, data: { alerts } }
  );

export const unsubscribePush = () => req<null>('DELETE', '/api/v1/push/subscription');

export const createDeco = (body: {
  slug: string;
  name: string;
  description?: string;
  name_i18n?: Record<string, string>;
  description_i18n?: Record<string, string>;
  local_only?: boolean;
  has_actor?: boolean;
  kind?: 'thread' | 'talk';
}) => req<Deco>('POST', '/api/v1/deco', body);

/**
 * いまログインしている人の、素の姿。板を立てる権限(admin かどうか)は
 * `role.name` から読む ── サーバの返す形は Mastodon 互換の verify_credentials。
 */
export async function getCurrentAccount(): Promise<CurrentAccount | null> {
  if (!signedIn()) return null;
  try {
    const body = await req<{
      username: string;
      acct: string;
      display_name: string;
      avatar_url: string | null;
      source?: { note?: string };
      role?: { name?: string };
    }>('GET', '/api/v1/accounts/verify_credentials');

    return {
      username: body.username,
      acct: body.acct,
      display_name: body.display_name,
      note: body.source?.note ?? '',
      avatar_url: body.avatar_url,
      isAdmin: body.role?.name === 'admin'
    };
  } catch {
    return null;
  }
}

export const updateProfile = (body: { display_name?: string; note?: string }) =>
  req<CurrentAccount>('PATCH', '/api/v1/accounts/update_credentials', body);

/** 「2 分前」くらいの、ゆるい時刻。掲示板の秒単位は要らないので。 */
export function when(iso: string): string {
  const then = new Date(iso).getTime();
  const mins = Math.floor((Date.now() - then) / 60000);
  const lang = getLang();
  if (lang === 'ko') {
    if (mins < 1) return '지금';
    if (mins < 60) return `${mins}분 전`;
    const hours = Math.floor(mins / 60);
    if (hours < 24) return `${hours}시간 전`;
    const days = Math.floor(hours / 24);
    if (days < 7) return `${days}일 전`;
    return new Date(iso).toLocaleDateString('ko-KR');
  }
  if (mins < 1) return 'いま';
  if (mins < 60) return `${mins} 分前`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours} 時間前`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days} 日前`;
  return new Date(iso).toLocaleDateString('ja-JP');
}
