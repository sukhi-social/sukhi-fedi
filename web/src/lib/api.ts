import { loadToken, tryRefresh, redirectToLogin } from './auth';
import { readPushConfig } from './push';

export type Field = {
  name: string;
  value: string;
  verified_at?: string | null;
};

export type Emoji = {
  shortcode: string;
  url: string;
  static_url?: string;
  visible_in_picker?: boolean;
};

export type Account = {
  id: string;
  username: string;
  acct: string;
  display_name: string;
  emojis?: Emoji[];
  avatar: string | null;
  avatar_static?: string | null;
  header?: string | null;
  header_static?: string | null;
  url: string;
  note?: string;
  locked?: boolean;
  bot?: boolean;
  discoverable?: boolean;
  indexable?: boolean;
  created_at?: string;
  followers_count?: number;
  following_count?: number;
  statuses_count?: number;
  fields?: Field[];
  // アカウント引っ越し(Mastodon Move)。moved は引っ越し先の最小アカウント、
  // 引っ越していなければ null。プロフィールに静かに「@new へ移りました」を
  // 出すための真実の状態 ─ 数字も煽りもなし。aliases は本人が宣言した
  // 「これも自分」の一覧。
  moved?: Account | null;
  aliases?: string[];
  // verify_credentials だけが返す。admin は { name: "admin", ... }。
  // 管理ページへの入口を出すかどうかの判定に使う。
  role?: { id: string; name: string; permissions: string } | null;
};

export type MediaAttachment = {
  id: string;
  type: string;
  url: string;
  preview_url?: string | null;
  description?: string | null;
};

export type Tag = {
  name: string;
  url: string;
};

export type Visibility = 'public' | 'unlisted' | 'private' | 'direct';

export type Status = {
  id: string;
  created_at: string;
  content: string;
  // Sukhi extension: the verbatim MFM source for a Misskey-family note
  // (absent on local posts and non-Misskey remotes). When present, the
  // client renders the static MFM subset from it instead of `content`.
  mfm?: string | null;
  // Sukhi extension: an Article's bare title (hackers.pub long-form post).
  // Present ⇒ this status is an article; we route it to its reader page.
  // The same title is also folded into `content` as a leading <h2>.
  title?: string | null;
  emojis?: Emoji[];
  spoiler_text?: string;
  sensitive?: boolean;
  visibility?: Visibility;
  in_reply_to_id?: string | null;
  in_reply_to_account_id?: string | null;
  account: Account;
  // Fedibird-compatible quote post, nested one level deep (no further).
  quote?: Status | null;
  // Boost (reblog): the boosted status, nested one level deep. Present only
  // on the wrapper status whose `account` is the booster.
  reblog?: Status | null;
  media_attachments: MediaAttachment[];
  tags: Tag[];
  url?: string;
  reactions?: Reaction[];
  favourited?: boolean;
  favourites_count?: number;
  reblogged?: boolean;
  reblogs_count?: number;
  bookmarked?: boolean;
  pinned?: boolean;
  poll?: Poll | null;
  card?: PreviewCard | null;
};

// FEP-8967 link preview card. A small subset of Mastodon's card entity —
// what the web actually renders under a post.
export type PreviewCard = {
  url: string;
  title: string;
  description: string;
  type: string;
  image?: string | null;
  provider_name: string;
};

// A status carries protected media when it has a CW (spoiler_text) or is
// flagged sensitive. The one place that answers "must this media stay
// covered?" — Status.svelte collapses/blurs by these same two fields, and
// the media grid covers a tile by this predicate (never auto-revealing).
export function statusMediaProtected(s: Status): boolean {
  return !!s.spoiler_text || s.sensitive === true;
}

export type PollOption = {
  title: string;
  votes_count?: number | null;
};

export type Poll = {
  id: string;
  expires_at?: string | null;
  expired: boolean;
  multiple: boolean;
  votes_count: number;
  voters_count?: number | null;
  options: PollOption[];
  emojis?: Emoji[];
  voted?: boolean;
  own_votes?: number[];
};

export type Reaction = {
  name: string;
  count: number;
  me: boolean;
  url?: string | null;
  static_url?: string | null;
};

export type Relationship = {
  id: string;
  following: boolean;
  followed_by: boolean;
  requested: boolean;
  blocking?: boolean;
  muting?: boolean;
  // あなただけに見える私的メモ。連合はしない、ローカルだけの呼び名。
  note?: string;
};

export type TimelineKind = 'home' | 'public' | 'bubble' | 'tag';

// ── core ─────────────────────────────────────────────────────────────
// Every call funnels through `req`. One place attaches the bearer (unless
// `auth: false`); on a 401 for an authed call it tries a single
// refresh-token grant and retries once with the fresh bearer, so an expired
// access token renews silently. If the refresh fails too, the session is
// dead and the user is bounced to login. It optionally maps a 404 to
// `not_found`, and turns any non-2xx into a thrown Error — its message is the
// server's `error` field when present, otherwise `<label>_failed_<status>`.
// The thin `json` / `page` wrappers shape the success side; `pageQs` builds the
// shared `limit` + `max_id` query for cursor-paginated lists.

function authHeader(): Record<string, string> {
  const t = loadToken();
  return t ? { authorization: `Bearer ${t.access_token}` } : {};
}

type ReqInit = {
  // true (default): attach bearer + log out on 401.
  // false: never attach (purely public).
  // 'optional': attach the bearer when logged in so the viewer is seen
  //   (own DMs, followers-only, fav/reaction flags), but a 401 here does
  //   NOT log out — an anonymous read of public content shouldn't end a
  //   stale session, and the server 401s an offered-but-bad token.
  auth?: boolean | 'optional';
  json?: unknown; // JSON request body
  form?: FormData; // multipart request body
  notFound?: boolean; // map a 404 to Error('not_found')
};

async function req(method: string, path: string, label: string, init: ReqInit = {}): Promise<Response> {
  const attachAuth = init.auth !== false;

  let body: BodyInit | undefined;
  const baseHeaders: Record<string, string> = { accept: 'application/json' };
  if (init.json !== undefined) {
    baseHeaders['content-type'] = 'application/json';
    body = JSON.stringify(init.json);
  } else if (init.form) {
    body = init.form;
  }

  // 送るたびに今の token を読む ─ refresh で差し替わった直後の再送が
  // 古い bearer を掴まないように。
  const send = () => {
    const headers = { ...baseHeaders };
    if (attachAuth) Object.assign(headers, authHeader());
    return fetch(path, { method, headers, body });
  };

  let res = await send();

  // authed (非 optional) な呼び出しが 401 = access token が切れたか
  // revoke された。まず refresh で取り直し、取れたら新しい bearer で
  // 一度だけ再送する (呼び元には透明)。取れない / 再送もまた 401 なら
  // セッションは戻せないので login へ落とす。optional は従来どおり
  // (匿名読みは 401 でもセッションを終わらせない) ので素通り。
  if (attachAuth && init.auth !== 'optional' && res.status === 401) {
    const refreshed = await tryRefresh();
    if (refreshed) res = await send();
    if (res.status === 401) {
      redirectToLogin();
      throw new Error('unauthorized');
    }
  }

  if (init.notFound && res.status === 404) throw new Error('not_found');
  if (!res.ok) {
    const err = (await res.json().catch(() => ({}))) as { error?: string };
    throw new Error(err?.error ?? `${label}_failed_${res.status}`);
  }
  return res;
}

async function json<T>(res: Response): Promise<T> {
  return (await res.json()) as T;
}

function parseLinkMaxId(link: string | null): string | null {
  if (!link) return null;
  for (const part of link.split(',')) {
    const m = part.match(/<([^>]+)>;\s*rel="next"/);
    if (m) {
      try {
        // サーバは同一オリジンの *相対* URL を返す
        // (`</api/v1/timelines/home?…max_id=N>`)。base 無しの `new URL`
        // は相対 URL で throw するので、現在オリジンを base に渡す。query
        // を読むだけなので絶対 URL が来てもそのまま通る。
        const u = new URL(m[1], location.origin);
        return u.searchParams.get('max_id');
      } catch {
        return null;
      }
    }
  }
  return null;
}

export type Page<T> = {
  items: T[];
  nextMaxId: string | null;
};

async function page<T>(res: Response): Promise<Page<T>> {
  return { items: await json<T[]>(res), nextMaxId: parseLinkMaxId(res.headers.get('link')) };
}

function pageQs(opts: { maxId?: string | null; limit?: number }, defaultLimit: number): URLSearchParams {
  const qs = new URLSearchParams();
  qs.set('limit', String(opts.limit ?? defaultLimit));
  if (opts.maxId) qs.set('max_id', opts.maxId);
  return qs;
}

// ── timelines ────────────────────────────────────────────────────────

export async function fetchTimeline(
  kind: TimelineKind,
  opts: {
    tag?: string;
    maxId?: string | null;
    limit?: number;
    onlyMedia?: boolean;
    hideBoosts?: boolean;
    hideSensitive?: boolean;
  } = {}
): Promise<Page<Status>> {
  const qs = pageQs(opts, 20);
  if (opts.onlyMedia) qs.set('only_media', '1');
  if (opts.hideBoosts) qs.set('hide_boosts', '1');
  if (opts.hideSensitive) qs.set('hide_sensitive', '1');

  let path: string;
  let auth = false;
  switch (kind) {
    case 'home':
      path = `/api/v1/timelines/home?${qs}`;
      auth = true;
      break;
    case 'public':
      qs.set('local', '1');
      path = `/api/v1/timelines/public?${qs}`;
      break;
    case 'bubble':
      // ご近所: 信頼できるご近所のサーバの公開投稿だけ。public 経由で畳む。
      qs.set('bubble', '1');
      path = `/api/v1/timelines/public?${qs}`;
      break;
    case 'tag':
      if (!opts.tag) throw new Error('tag required');
      path = `/api/v1/timelines/tag/${encodeURIComponent(opts.tag)}?${qs}`;
      break;
  }

  return page<Status>(await req('GET', path, 'timeline', { auth }));
}

// ── conversations (DM) ───────────────────────────────────────────────

export type Conversation = {
  id: string;
  unread: boolean;
  accounts: Account[];
  last_status: Status | null;
};

export async function getConversations(
  opts: { maxId?: string | null; limit?: number } = {}
): Promise<Page<Conversation>> {
  return page<Conversation>(await req('GET', `/api/v1/conversations?${pageQs(opts, 20)}`, 'conversations'));
}

// 会話の中身。新しい順、note id でページング。
//
// Mastodon には無い口(sukhi の追加)。会話は conversation_ap_id で束ねられて
// いるので、返信鎖を歩かずに列として読める ── 深さの天井も、深さごとの
// クエリも無い。鎖から外れた一通(スレッドの外から書かれた DM)も出る。
export async function getConversationStatuses(
  id: string,
  opts: { maxId?: string | null; sinceId?: string | null; limit?: number } = {}
): Promise<Page<Status>> {
  const qs = pageQs(opts, 30);
  // 取りこぼしの拾い直し用。手元の最新より新しいぶんだけを引く。
  if (opts.sinceId) qs.set('since_id', opts.sinceId);
  return page<Status>(
    await req(
      'GET',
      `/api/v1/conversations/${encodeURIComponent(id)}/statuses?${qs}`,
      'conversation_statuses'
    )
  );
}

export async function markConversationRead(id: string): Promise<Conversation> {
  return json(
    await req('POST', `/api/v1/conversations/${encodeURIComponent(id)}/read`, 'conversation_read', { json: {} })
  );
}

// ── statuses ─────────────────────────────────────────────────────────

export type ComposeInput = {
  status: string;
  spoiler_text?: string;
  sensitive?: boolean;
  visibility?: Visibility;
  in_reply_to_id?: string | null;
  // 引用元の投稿 id。立てると、その投稿を引用したノートになる
  // (サーバは quote_of_ap_id へ解決して連合に流す)。
  quote_id?: string | null;
  media_ids?: string[];
  // ISO-8601 instant. When set, the server stores the post and publishes
  // it then, returning a ScheduledStatus instead of a Status.
  scheduled_at?: string | null;
};

export async function postStatus(input: ComposeInput): Promise<Status> {
  // null / undefined / 空配列をそぎ落として送る。送らないことが
  // 「サーバ既定」を意味する API なので、こちらで余計なキーを入れない。
  const body: Record<string, unknown> = { status: input.status };
  if (input.spoiler_text) body.spoiler_text = input.spoiler_text;
  if (input.sensitive) body.sensitive = true;
  if (input.visibility) body.visibility = input.visibility;
  if (input.in_reply_to_id) body.in_reply_to_id = input.in_reply_to_id;
  if (input.quote_id) body.quote_id = input.quote_id;
  if (input.media_ids && input.media_ids.length > 0) body.media_ids = input.media_ids;
  if (input.scheduled_at) body.scheduled_at = input.scheduled_at;

  return json(await req('POST', '/api/v1/statuses', 'post', { json: body }));
}

// Delete one of your own notes. The gateway enforces ownership (a
// non-owner gets 403); the deleted Status JSON Mastodon returns is
// unused, so resolve void.
export async function deleteStatus(statusId: string): Promise<void> {
  await req('DELETE', `/api/v1/statuses/${encodeURIComponent(statusId)}`, 'delete');
}

// ── compose draft (server, cross-device) ─────────────────────────────
// The Misskey-native `/api/i/notes/drafts` surface: one draft per
// account, never federated. The local `sf.compose_draft` cache
// (compose-draft.ts) syncs through these. 'optional' auth — a draft
// sync that 401s shouldn't end a session (the composer falls back to the
// local copy and the rest of the SPA still authenticates normally).

export type ServerDraft = {
  text: string;
  spoiler: string;
  useSpoiler: boolean;
  sensitive: boolean;
  visibility: Visibility;
  updated_at: string | null;
};

// null = no server draft yet (204).
export async function getServerDraft(): Promise<ServerDraft | null> {
  const res = await req('GET', '/api/i/notes/drafts', 'draft_get', { auth: 'optional' });
  if (res.status === 204) return null;
  return json<ServerDraft>(res);
}

export async function putServerDraft(d: {
  text: string;
  spoiler: string;
  useSpoiler: boolean;
  sensitive: boolean;
  visibility: Visibility;
}): Promise<ServerDraft> {
  return json<ServerDraft>(await req('PUT', '/api/i/notes/drafts', 'draft_put', { auth: 'optional', json: d }));
}

export async function deleteServerDraft(): Promise<void> {
  await req('DELETE', '/api/i/notes/drafts', 'draft_delete', { auth: 'optional' });
}

// ── web push ─────────────────────────────────────────────────────────
// `direct_types` は sukhi の足しもの(Mastodon には無い)。どの通知なら人を
// 起こしていいかはサーバが決めるので、手元では一覧を持たない。

export type PushSubscriptionRow = {
  id: string;
  endpoint: string;
  alerts: Record<string, boolean>;
  server_key: string | null;
  direct_types?: string[];
};

export type PushConfig = { serverKey: string | null; directTypes: string[] };

/**
 * サーバの鍵と、鳴っていい種類。
 *
 * **購読より先に要る。** `/push/subscription` は購読が無いと 404 なので、
 * そこだけ見ていると「このサーバでは push をやっていない」と「まだ購読して
 * いない」が見分けられない。見分けられないまま釦を出すと、ブラウザの許可を
 * 一度きり使ってから「鍵がありません」になる。
 */
export async function getPushConfig(): Promise<PushConfig> {
  try {
    // v2。configuration の一式はこちらにしかない ── v1 を見ていると、
    // 鍵が置かれたあとも「無い」と読み続けて、釦が永久に出ない。
    // (隠れているのが正しく見えてしまうので、気づきにくい間違い。)
    const res = await req('GET', '/api/v2/instance', 'instance', { auth: false });
    return readPushConfig(await res.json());
  } catch {
    // 訊けなかったら「やっていない」に倒す。出さないほうが、押して
    // 何も起きないよりいい。
    return { serverKey: null, directTypes: [] };
  }
}

/** いまの購読。していなければ null(404)。 */
export async function getPushSubscription(): Promise<PushSubscriptionRow | null> {
  const res = await req('GET', '/api/v1/push/subscription', 'push_get', { auth: 'optional' });
  if (res.status === 404) return null;
  return json<PushSubscriptionRow>(res);
}

export async function putPushSubscription(input: {
  endpoint: string;
  keys: { p256dh: string; auth: string };
  alerts: Record<string, boolean>;
}): Promise<PushSubscriptionRow> {
  return json<PushSubscriptionRow>(
    await req('POST', '/api/v1/push/subscription', 'push_post', {
      auth: 'optional',
      json: {
        subscription: { endpoint: input.endpoint, keys: input.keys },
        data: { alerts: input.alerts }
      }
    })
  );
}

export async function deletePushSubscription(): Promise<void> {
  await req('DELETE', '/api/v1/push/subscription', 'push_delete', { auth: 'optional' });
}

// ── interactions ─────────────────────────────────────────────────────
// Each toggle returns the updated Status.

async function statusAction(method: string, path: string): Promise<Status> {
  return json<Status>(await req(method, path, 'action'));
}

const statusPath = (id: string, action: string) => `/api/v1/statuses/${encodeURIComponent(id)}/${action}`;
const reactPath = (id: string, emoji: string) =>
  `/api/v1/sukhi/statuses/${encodeURIComponent(id)}/react/${encodeURIComponent(emoji)}`;

export const favourite = (id: string) => statusAction('POST', statusPath(id, 'favourite'));
export const unfavourite = (id: string) => statusAction('POST', statusPath(id, 'unfavourite'));
export const reblog = (id: string) => statusAction('POST', statusPath(id, 'reblog'));
export const unreblog = (id: string) => statusAction('POST', statusPath(id, 'unreblog'));
export const bookmark = (id: string) => statusAction('POST', statusPath(id, 'bookmark'));
export const unbookmark = (id: string) => statusAction('POST', statusPath(id, 'unbookmark'));
// pin/unpin は自分の投稿だけ。サーバが ownership を強制し、非所有者は 403。
export const pinStatus = (id: string) => statusAction('POST', statusPath(id, 'pin'));
export const unpinStatus = (id: string) => statusAction('POST', statusPath(id, 'unpin'));
export const react = (id: string, emoji: string) => statusAction('PUT', reactPath(id, emoji));
export const unreact = (id: string, emoji: string) => statusAction('DELETE', reactPath(id, emoji));

export async function getBookmarks(
  opts: { maxId?: string | null; limit?: number } = {}
): Promise<Page<Status>> {
  return page<Status>(await req('GET', `/api/v1/bookmarks?${pageQs(opts, 20)}`, 'bookmarks'));
}

export async function getFavourites(
  opts: { maxId?: string | null; limit?: number } = {}
): Promise<Page<Status>> {
  return page<Status>(await req('GET', `/api/v1/favourites?${pageQs(opts, 20)}`, 'favourites'));
}

// ── polls ────────────────────────────────────────────────────────────

// choices は選んだ選択肢の index 配列。single choice の投票でも配列で送る
// のが Mastodon の仕様。返ってくるのは最新の集計を載せた Poll。
export async function votePoll(pollId: string, choices: number[]): Promise<Poll> {
  return json(
    await req('POST', `/api/v1/polls/${encodeURIComponent(pollId)}/votes`, 'vote', {
      json: { choices: choices.map(String) }
    })
  );
}

// ── media ────────────────────────────────────────────────────────────

export async function uploadMedia(file: File, description?: string): Promise<MediaAttachment> {
  const fd = new FormData();
  fd.set('file', file);
  if (description) fd.set('description', description);
  // v1 は同期で返す。v2 は処理中なら 202 を返して
  // /api/v1/media/:id で polling、というのが Mastodon の仕様。
  // 最初は v1 のシンプルさを取る。重い変換が要るときは server 側で
  // 設定するか、別途 v2 にスイッチ。
  return json(await req('POST', '/api/v1/media', 'media', { form: fd }));
}

// ── accounts: self ───────────────────────────────────────────────────

export async function verifyCredentials(): Promise<Account> {
  return json(await req('GET', '/api/v1/accounts/verify_credentials', 'verify'));
}

// Memoised logged-in account, for "is this mine?" UI checks (delete on a
// status) and the nav avatar. Cached so a timeline of N statuses plus the
// nav cost one verify_credentials call, not N+1. Resolves null when logged
// out or on a lookup miss; the memo clears itself once the token is gone,
// so a re-login fetches the new account fresh rather than the stale one.
let mePromise: Promise<Account | null> | null = null;

export function currentAccount(): Promise<Account | null> {
  if (!loadToken()) {
    mePromise = null;
    return Promise.resolve(null);
  }

  if (!mePromise) {
    mePromise = verifyCredentials().catch(() => {
      mePromise = null; // let a later call retry after a transient failure
      return null;
    });
  }

  return mePromise;
}

export function currentAccountId(): Promise<string | null> {
  return currentAccount().then((a) => a?.id ?? null);
}

// Overwrite the memoised account. Call after a profile save so the nav
// avatar (and "is this mine?" checks) pick up the new image on the next
// read — otherwise the memo keeps serving the pre-save account and the old
// avatar lingers as an afterimage until a full reload.
export function setCurrentAccount(account: Account): void {
  mePromise = Promise.resolve(account);
}

export type CredentialsUpdate = {
  display_name?: string;
  note?: string;
  avatar?: File | null;
  header?: File | null;
  locked?: boolean;
  // Search-indexing consent (FEP-5feb). `discoverable` lets this account
  // surface in discovery places; `indexable` lets full-text search reach
  // its posts. Both default off — the server only flips them when asked.
  discoverable?: boolean;
  indexable?: boolean;
  // Profile fields, sent as one JSON-encoded part. The server sanitizes
  // and caps them; an empty array clears the rows.
  fields?: { name: string; value: string }[];
};

export async function updateCredentials(input: CredentialsUpdate): Promise<Account> {
  const fd = new FormData();
  if (input.display_name !== undefined) fd.set('display_name', input.display_name);
  if (input.note !== undefined) fd.set('note', input.note);
  if (input.locked !== undefined) fd.set('locked', input.locked ? 'true' : 'false');
  if (input.discoverable !== undefined)
    fd.set('discoverable', input.discoverable ? 'true' : 'false');
  if (input.indexable !== undefined) fd.set('indexable', input.indexable ? 'true' : 'false');
  if (input.fields !== undefined) fd.set('fields', JSON.stringify(input.fields));
  if (input.avatar) fd.set('avatar', input.avatar);
  if (input.header) fd.set('header', input.header);

  return json(await req('PATCH', '/api/v1/accounts/update_credentials', 'update', { form: fd }));
}

// ── follow requests (locked-account inbound approval) ────────────────
// A locked account holds inbound follows until the owner decides. The
// list is the accounts waiting; authorize/reject answer one of them.

export async function getFollowRequests(): Promise<Account[]> {
  return json(await req('GET', '/api/v1/follow_requests', 'follow_requests'));
}

export async function authorizeFollowRequest(id: string): Promise<Relationship> {
  return json(
    await req(
      'POST',
      `/api/v1/follow_requests/${encodeURIComponent(id)}/authorize`,
      'fr_authorize'
    )
  );
}

export async function rejectFollowRequest(id: string): Promise<Relationship> {
  return json(
    await req('POST', `/api/v1/follow_requests/${encodeURIComponent(id)}/reject`, 'fr_reject')
  );
}

// ── follow invites (FEP-bebd) ────────────────────────────────────────
// A locked account mints codes that let a holder skip the approval queue.
// The shareable link is built from the code against this origin.

export type FollowInvite = { code: string };

export async function getFollowInvites(): Promise<FollowInvite[]> {
  return json(await req('GET', '/api/v1/follow_invites', 'follow_invites_list'));
}

export async function createFollowInvite(): Promise<FollowInvite> {
  return json(await req('POST', '/api/v1/follow_invites', 'follow_invite_create'));
}

export async function deleteFollowInvite(code: string): Promise<void> {
  await req(
    'DELETE',
    `/api/v1/follow_invites/${encodeURIComponent(code)}`,
    'follow_invite_delete'
  );
}

// ── announcements (server notices) ───────────────────────────────────
// Local-only notices the admin pins for everyone on the box. `read` is
// whether this account has dismissed it; dismissing is what makes a
// notice go quiet for good.

export type Announcement = {
  id: string;
  content: string;
  starts_at: string | null;
  ends_at: string | null;
  published_at: string | null;
  read: boolean;
};

export async function getAnnouncements(): Promise<Announcement[]> {
  return json(await req('GET', '/api/v1/announcements', 'announcements'));
}

export async function dismissAnnouncement(id: string): Promise<void> {
  await req('POST', `/api/v1/announcements/${encodeURIComponent(id)}/dismiss`, 'announcement_dismiss');
}

// ── account migration (Move + alsoKnownAs) ───────────────────────────

export type AccountMigration = {
  aliases: string[];
  moved_to: string | null;
};

export async function getMigration(): Promise<AccountMigration> {
  return json(await req('GET', '/api/v1/accounts/migration', 'migration'));
}

// 別名(alsoKnownAs)の一覧をまるごと差し替える。サーバが妥当性と上限を
// 見るので、ここは送るだけ。引っ越し先がこちらを別名に入れていることが、
// Move を受ける側の同意になる。
export async function setAliases(aliases: string[]): Promise<{ aliases: string[] }> {
  return json(
    await req('POST', '/api/v1/accounts/migration/aliases', 'aliases', { json: { aliases } })
  );
}

// このアカウントを target へ引っ越す。target が alsoKnownAs にこちらを
// 入れていない(双方向の同意がない)場合は 422 で返る。
export async function moveAccount(target: string): Promise<{ moved_to: string | null }> {
  return json(await req('POST', '/api/v1/accounts/migration/move', 'move', { json: { target } }));
}

// ── accounts: lookup / show ──────────────────────────────────────────

export async function lookupAccount(acct: string): Promise<Account> {
  const qs = new URLSearchParams({ acct });
  return json(await req('GET', `/api/v1/accounts/lookup?${qs}`, 'lookup', { auth: false, notFound: true }));
}

export async function getAccount(id: string): Promise<Account> {
  return json(
    await req('GET', `/api/v1/accounts/${encodeURIComponent(id)}`, 'account', { auth: false, notFound: true })
  );
}

// 返信の「返信先」表示など、同じアカウントを何度も引く場面用に Promise を
// 覚えておく ── 同時に複数のカードが同じ相手を引いても 1 リクエストに束ね、
// 再描画でも引き直さない。失敗したら忘れて次回また取りに行けるようにする。
const accountByIdCache = new Map<string, Promise<Account>>();

export function getAccountCached(id: string): Promise<Account> {
  let p = accountByIdCache.get(id);
  if (!p) {
    p = getAccount(id).catch((e) => {
      accountByIdCache.delete(id);
      throw e;
    });
    accountByIdCache.set(id, p);
  }
  return p;
}

export async function getAccountStatuses(
  id: string,
  opts: { maxId?: string | null; limit?: number; pinned?: boolean; articles?: boolean; onlyMedia?: boolean } = {}
): Promise<Page<Status>> {
  const qs = pageQs(opts, 20);
  if (opts.pinned) qs.set('pinned', 'true');
  // Sukhi extension: the profile's Articles tab (notes with a title).
  if (opts.articles) qs.set('only_articles', 'true');
  if (opts.onlyMedia) qs.set('only_media', '1');
  const path = `/api/v1/accounts/${encodeURIComponent(id)}/statuses?${qs}`;
  // 'optional' so a logged-in viewer sees their own followers-only posts
  // (and accepted-follower posts) on the profile, plus fav/reaction flags.
  return page<Status>(await req('GET', path, 'account_statuses', { auth: 'optional' }));
}

export async function getStatus(id: string): Promise<Status> {
  return json(
    await req('GET', `/api/v1/statuses/${encodeURIComponent(id)}`, 'status', { auth: 'optional', notFound: true })
  );
}

export type Context = { ancestors: Status[]; descendants: Status[] };

export async function getContext(id: string): Promise<Context> {
  return json(
    await req('GET', `/api/v1/statuses/${encodeURIComponent(id)}/context`, 'context', { auth: 'optional' })
  );
}

async function fetchAccountList(
  endpoint: 'followers' | 'following',
  id: string,
  opts: { maxId?: string | null; limit?: number } = {}
): Promise<Page<Account>> {
  const path = `/api/v1/accounts/${encodeURIComponent(id)}/${endpoint}?${pageQs(opts, 40)}`;
  return page<Account>(await req('GET', path, endpoint, { auth: false }));
}

export const getAccountFollowers = (id: string, opts?: { maxId?: string | null; limit?: number }) =>
  fetchAccountList('followers', id, opts);

export const getAccountFollowing = (id: string, opts?: { maxId?: string | null; limit?: number }) =>
  fetchAccountList('following', id, opts);

// ── follows ──────────────────────────────────────────────────────────

export async function getRelationships(ids: string[]): Promise<Relationship[]> {
  if (ids.length === 0) return [];
  const qs = new URLSearchParams();
  for (const id of ids) qs.append('id[]', id);
  return json(await req('GET', `/api/v1/accounts/relationships?${qs}`, 'relationships'));
}

export async function followAccount(id: string): Promise<Relationship> {
  return json(await req('POST', `/api/v1/accounts/${encodeURIComponent(id)}/follow`, 'follow', { json: {} }));
}

export async function unfollowAccount(id: string): Promise<Relationship> {
  return json(await req('POST', `/api/v1/accounts/${encodeURIComponent(id)}/unfollow`, 'unfollow', { json: {} }));
}

// ── search ───────────────────────────────────────────────────────────

export type SearchResult = {
  accounts: Account[];
  hashtags: Tag[];
  statuses: Status[];
};

// resolve=true は WebFinger で remote actor を取りにいく(初フォロー
// の前段)。auth 必須。q 未入力なら空結果を返して silent に no-op。
export async function searchAll(
  q: string,
  opts: { resolve?: boolean; limit?: number; type?: 'accounts' | 'hashtags' | 'statuses' } = {}
): Promise<SearchResult> {
  const trimmed = q.trim();
  if (!trimmed) return { accounts: [], hashtags: [], statuses: [] };

  const qs = new URLSearchParams();
  qs.set('q', trimmed);
  if (opts.resolve) qs.set('resolve', 'true');
  if (opts.limit) qs.set('limit', String(opts.limit));
  if (opts.type) qs.set('type', opts.type);

  return json(await req('GET', `/api/v2/search?${qs}`, 'search'));
}

// ── notifications ────────────────────────────────────────────────────

export type NotificationType =
  | 'favourite'
  | 'reblog'
  | 'follow'
  | 'follow_request'
  | 'mention'
  | 'status'
  | 'poll'
  | 'update'
  // Sukhi 拡張のリアクション通知。サーバが未対応でも型として許す。
  | 'reaction';

export type Notification = {
  id: string;
  type: NotificationType;
  created_at: string;
  account: Account;
  status?: Status | null;
};

export async function getNotifications(
  opts: {
    maxId?: string | null;
    limit?: number;
    types?: NotificationType[];
    excludeTypes?: NotificationType[];
  } = {}
): Promise<Page<Notification>> {
  const qs = pageQs(opts, 30);
  for (const t of opts.types ?? []) qs.append('types[]', t);
  for (const t of opts.excludeTypes ?? []) qs.append('exclude_types[]', t);
  return page<Notification>(await req('GET', `/api/v1/notifications?${qs}`, 'notifications'));
}

export async function dismissNotification(id: string): Promise<void> {
  await req('POST', `/api/v1/notifications/${encodeURIComponent(id)}/dismiss`, 'dismiss', { json: {} });
}

export async function clearNotifications(): Promise<void> {
  await req('POST', '/api/v1/notifications/clear', 'clear', { json: {} });
}

// ── moderation: block / mute ─────────────────────────────────────────
// block/unblock/mute/unmute はどれも更新後の Relationship を返す。

function relAction(path: string): Promise<Relationship> {
  return req('POST', path, 'rel_action', { json: {} }).then((r) => json<Relationship>(r));
}

export const blockAccount = (id: string) => relAction(`/api/v1/accounts/${encodeURIComponent(id)}/block`);
export const unblockAccount = (id: string) => relAction(`/api/v1/accounts/${encodeURIComponent(id)}/unblock`);
export const muteAccount = (id: string) => relAction(`/api/v1/accounts/${encodeURIComponent(id)}/mute`);
export const unmuteAccount = (id: string) => relAction(`/api/v1/accounts/${encodeURIComponent(id)}/unmute`);

// 私的メモ(あなただけに見える呼び名)を書く / 消す。空文字で消える。
// 連合はしない、ローカルだけの約束。更新後の Relationship を返す。
export function setAccountNote(id: string, comment: string): Promise<Relationship> {
  return req('POST', `/api/v1/accounts/${encodeURIComponent(id)}/note`, 'set_note', {
    json: { comment }
  }).then((r) => json<Relationship>(r));
}

// blocks/mutes 一覧はサーバ側がページネーションせず全件返す（Account 配列）。
export async function getBlocks(): Promise<Account[]> {
  return json(await req('GET', '/api/v1/blocks', 'blocks'));
}

export async function getMutes(): Promise<Account[]> {
  return json(await req('GET', '/api/v1/mutes', 'mutes'));
}

// 通報。account_id は必須、status_ids と comment は任意。サーバは確認だけ
// 返す（UI では使わない）ので void。
export type ReportInput = { statusIds?: string[]; comment?: string };

export async function reportAccount(accountId: string, input: ReportInput = {}): Promise<void> {
  const body: Record<string, unknown> = { account_id: accountId };
  if (input.statusIds && input.statusIds.length > 0) body.status_ids = input.statusIds;
  if (input.comment) body.comment = input.comment;
  await req('POST', '/api/v1/reports', 'report', { json: body });
}

// ── lists ────────────────────────────────────────────────────────────

export type RepliesPolicy = 'list' | 'followed' | 'none';

// ホームの返信の扱い: all=制限なし / hide=返信を出さない / to_me=自分宛の返信だけ。
export type HomeReplies = 'all' | 'hide' | 'to_me';

export type List = {
  id: string;
  title: string;
  replies_policy: RepliesPolicy;
  exclusive: boolean;
  filter_only_media: boolean;
  filter_hide_boosts: boolean;
  filter_hide_sensitive: boolean;
  filter_keyword: string;
  filter_replies: HomeReplies;
};

export type ListAttrs = {
  title?: string;
  repliesPolicy?: RepliesPolicy;
  exclusive?: boolean;
  filterOnlyMedia?: boolean;
  filterHideBoosts?: boolean;
  filterHideSensitive?: boolean;
  filterKeyword?: string;
  filterReplies?: HomeReplies;
};

// title 以外は省略可（サーバ既定に委ねる）。camelCase → snake_case はここで。
function listBody(attrs: ListAttrs): Record<string, unknown> {
  const body: Record<string, unknown> = {};
  if (attrs.title !== undefined) body.title = attrs.title;
  if (attrs.repliesPolicy) body.replies_policy = attrs.repliesPolicy;
  if (attrs.exclusive !== undefined) body.exclusive = attrs.exclusive;
  if (attrs.filterOnlyMedia !== undefined) body.filter_only_media = attrs.filterOnlyMedia;
  if (attrs.filterHideBoosts !== undefined) body.filter_hide_boosts = attrs.filterHideBoosts;
  if (attrs.filterHideSensitive !== undefined) body.filter_hide_sensitive = attrs.filterHideSensitive;
  if (attrs.filterKeyword !== undefined) body.filter_keyword = attrs.filterKeyword;
  if (attrs.filterReplies !== undefined) body.filter_replies = attrs.filterReplies;
  return body;
}

export async function getLists(): Promise<List[]> {
  return json(await req('GET', '/api/v1/lists', 'lists'));
}

export async function getList(id: string): Promise<List> {
  return json(await req('GET', `/api/v1/lists/${encodeURIComponent(id)}`, 'list', { notFound: true }));
}

export async function createList(title: string, attrs: Omit<ListAttrs, 'title'> = {}): Promise<List> {
  return json(await req('POST', '/api/v1/lists', 'list_create', { json: listBody({ title, ...attrs }) }));
}

export async function updateList(id: string, attrs: ListAttrs): Promise<List> {
  return json(await req('PUT', `/api/v1/lists/${encodeURIComponent(id)}`, 'list_update', { json: listBody(attrs) }));
}

export async function deleteList(id: string): Promise<void> {
  await req('DELETE', `/api/v1/lists/${encodeURIComponent(id)}`, 'list_delete');
}

// メンバー一覧はサーバ側がページネーションせず全件返す（Account 配列）。
export async function getListAccounts(id: string): Promise<Account[]> {
  return json(await req('GET', `/api/v1/lists/${encodeURIComponent(id)}/accounts`, 'list_accounts'));
}

export async function addToList(id: string, accountIds: string[]): Promise<void> {
  await req('POST', `/api/v1/lists/${encodeURIComponent(id)}/accounts`, 'list_add', {
    json: { account_ids: accountIds }
  });
}

export async function removeFromList(id: string, accountIds: string[]): Promise<void> {
  await req('DELETE', `/api/v1/lists/${encodeURIComponent(id)}/accounts`, 'list_remove', {
    json: { account_ids: accountIds }
  });
}

export async function fetchListTimeline(
  id: string,
  opts: { maxId?: string | null; limit?: number; onlyMedia?: boolean; hideSensitive?: boolean } = {}
): Promise<Page<Status>> {
  const qs = pageQs(opts, 20);
  if (opts.onlyMedia) qs.set('only_media', '1');
  if (opts.hideSensitive) qs.set('hide_sensitive', '1');
  const path = `/api/v1/timelines/list/${encodeURIComponent(id)}?${qs}`;
  return page<Status>(await req('GET', path, 'list_timeline'));
}
