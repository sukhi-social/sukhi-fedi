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
  // 読む人ごとの印。気にかけているか／最後に見たあとに動きがあったか。
  //
  // 気にかけているかは **書いたことがあるか** から出る ── 押して宣言
  // するものではない（Zulip の participation）。読んでいるだけの板は、
  // 板の中の詳細設定（`notify`）で寄せられる。
  //
  // **並びには使わない** ── 上に寄せるのは読む側の仕事で、その中も
  // 外も名前順のまま。数は数えない（光るだけ）。
  minding: boolean;
  unread: boolean;
  notify: DecoNotify;
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

// ── 人（fediverse 側） ─────────────────────────────────────────────
//
// natadeco のアカウントは本物の fediverse actor なのに、これまで画面が
// 一枚も無かった ── 外からは追えるのに、こちらから外を見られない片道の
// 扉になっていた。ここはその扉のこちら側。

export type Person = {
  id: string;
  username: string;
  acct: string;
  display_name: string;
  note: string;
  avatar: string;
  url: string;
  followers_count: number;
  following_count: number;
  statuses_count: number;
  bot: boolean;
};

export type Relationship = {
  id: string;
  following: boolean;
  followed_by: boolean;
  requested: boolean;
};

/** Mastodon の Status。友デコが受け取る形（deco の Post とは別もの）。 */
type Status = {
  id: string;
  created_at: string;
  content: string;
  visibility: string;
  account: Person;
  emojis: Emoji[];
  reactions: Reaction[];
  in_reply_to_id: string | null;
  parent?: { id: string; author: Author; excerpt: string } | null;
};

/**
 * Status を、流れの一行（`Flow.svelte` が読む形）に写す。
 *
 * 板の投稿と友達の投稿は出どころが違うだけで、画面での姿は同じ ──
 * 平らに、書かれた順に、返信は親を一段だけ抱えて。描きかたを二つ
 * 持たないために、ここで形のほうを揃える。
 */
function fromStatus(s: Status): Post {
  return {
    id: s.id as unknown as number,
    deco_id: 0,
    title: null,
    title_i18n: {},
    content: '',
    content_i18n: {},
    content_html: s.content,
    content_html_i18n: {},
    author: {
      username: s.account.username,
      acct: s.account.acct,
      display_name: s.account.display_name,
      avatar_url: s.account.avatar
    },
    created_at: s.created_at,
    reply_count: 0,
    // 友デコには板の「ここだけ」の印は無い ── 出どころが板ではないので。
    local_only: false,
    emojis: s.emojis ?? [],
    reactions: s.reactions ?? [],
    parent: s.parent
      ? { id: s.parent.id as unknown as number, author: s.parent.author, excerpt: s.parent.excerpt }
      : null
  };
}

/**
 * 友デコ。追っている人が言ったことだけ ── 自分の投稿は入らない。
 *
 * 自分の行が自分の面に居るのは、反応の付かない自分の投稿を自分で
 * 何度も見ることでもある。出したことは板で見えるし、会話の筋は返信が
 * 親を抱えるので読めるし、反応が来たかは通知が持っている。
 */
export async function listFriends(opts: { maxId?: string; since?: Date } = {}) {
  const q = new URLSearchParams({ exclude_self: 'true', hide_boosts: 'true', limit: '40' });
  if (opts.maxId) q.set('max_id', opts.maxId);
  if (opts.since) q.set('since_id', snowflakeAt(opts.since));
  const rows = await req<Status[]>('GET', `/api/v1/timelines/home?${q}`);
  return rows.map(fromStatus);
}

/**
 * 読む人の時計の一瞬を、note の id と同じ物差しに直す。
 *
 * Mastodon のページングは id 基準なので、「今日のぶんで終わる」には
 * 真夜中を id にして渡すしかない。id の時刻は 2024-01-01 からのミリ秒を
 * 16 bit ずらしたもの（サーバの `SukhiFedi.Snowflake` と同じ形）。
 * ここだけはサーバの定数を持たざるを得ない ── deco の `/flow` は
 * 時刻をそのまま受ける口があるが、Mastodon の home には無い。
 */
const SNOWFLAKE_EPOCH_MS = 1704067200000;

function snowflakeAt(d: Date): string {
  return ((BigInt(d.getTime() - SNOWFLAKE_EPOCH_MS) << 16n) | 0n).toString();
}

export const getPerson = (id: string) => req<Person>('GET', `/api/v1/accounts/${id}`);

/** `alice@example.tld` を、まだ知らない相手でも取りに行く（WebFinger）。 */
export const findPerson = (q: string) =>
  req<{ accounts: Person[] }>(
    'GET',
    `/api/v2/search?type=accounts&resolve=true&limit=5&q=${encodeURIComponent(q)}`
  );

export const relationships = (ids: string[]) =>
  req<Relationship[]>(
    'GET',
    `/api/v1/accounts/relationships?${ids.map((i) => `id[]=${encodeURIComponent(i)}`).join('&')}`
  );

export const follow = (id: string) => req<Relationship>('POST', `/api/v1/accounts/${id}/follow`);
export const unfollow = (id: string) => req<Relationship>('POST', `/api/v1/accounts/${id}/unfollow`);

export const personPosts = (id: string) =>
  req<Status[]>('GET', `/api/v1/accounts/${id}/statuses?limit=20`).then((r) => r.map(fromStatus));

/** 友デコの中の返事。板ではなく、その人へ届く。 */
export const replyToPerson = (inReplyToId: string, status: string) =>
  req<Status>('POST', '/api/v1/statuses', { status, in_reply_to_id: inReplyToId });

// ── 通知 ──────────────────────────────────────────────────────────
//
// 友デコを出すと「返事が来ても気づけない」が目に見える形になるので、
// 一緒に置く。数は出さない（`web/src/lib/notify.ts` の ambient の考え）
// ── 数字は圧になるし、友達が増えるほど永遠に残るので。

export type Notice = {
  id: string;
  type: 'favourite' | 'reblog' | 'follow' | 'mention' | 'status' | 'follow_request' | 'poll' | 'update';
  created_at: string;
  account: Person;
  status: { id: string; content: string; emojis?: Emoji[] } | null;
};

export const listNotices = () => req<Notice[]>('GET', '/api/v1/notifications?limit=40');

/** 「ここまで読んだ」。`/api/v1/markers` は Mastodon の口をそのまま。 */
export const getReadMarker = () =>
  req<{ notifications?: { last_read_id: string } }>('GET', '/api/v1/markers?timeline[]=notifications')
    .then((m) => m.notifications?.last_read_id ?? null)
    .catch(() => null);

export const setReadMarker = (lastReadId: string) =>
  req('POST', '/api/v1/markers', { notifications: { last_read_id: lastReadId } }).catch(() => null);

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

const decoPath = (slug: string, tail: string) =>
  `/api/v1/deco/${encodeURIComponent(slug)}/${tail}`;

/**
 * この板を、どう知らせてほしいか。
 *
 *   participating — 既定。自分が書いた話だけ気にかける
 *   all           — 読んでいるだけでも気にかける
 *   quiet         — 光らない
 */
export type DecoNotify = 'participating' | 'all' | 'quiet';

export const setDecoNotify = (slug: string, notify: DecoNotify) =>
  req<{ notify: DecoNotify }>('PUT', decoPath(slug, 'notify'), { notify });

/** その板を、いま見た。光りが消える。 */
export const seenDeco = (slug: string) => req<{ seen: boolean }>('POST', decoPath(slug, 'seen'));

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
