// SPDX-License-Identifier: AGPL-3.0-or-later
// gateway(Mastodon 互換 + sukhi 拡張)が返す形。sukhi-web-next の api.ts から、型だけ写した。
export type Field = {
  name: string;
  value: string;
  verified_at?: string | null;
};

export type Emoji = {
  shortcode: string;
  url: string;
  static_url?: string;
  category?: string | null;
  aliases?: string[];
  visible_in_picker?: boolean;
};

// Misskey 系の飾り。angle は一周=1、offset はアイコンの大きさに対する割合。
export type AvatarDecoration = {
  url: string;
  angle: number;
  flip_h: boolean;
  offset_x: number;
  offset_y: number;
};

export type Account = {
  id: string;
  // verify_credentials のときだけ付く。language は、sukhi に置いた自分の言語(未設定なら null)。
  source?: { language?: string | null };
  username: string;
  acct: string;
  display_name: string;
  emojis?: Emoji[];
  avatar: string | null;
  avatar_static?: string | null;
  avatar_decorations?: AvatarDecoration[];
  header?: string | null;
  header_static?: string | null;
  url: string;
  note?: string;
  // verify_credentials のみ。自己紹介を書いたままの Markdown 原文。
  source?: { note?: string; fields?: { name: string; value: string }[] };
  // 管理者が渡した公開バッジ（Moderator など）。color は #hex か空。
  // Misskey 式のプロフィール項目。birthday は YYYY-MM-DD。
  location?: string | null;
  birthday?: string | null;
  roles?: { id: string; name: string; color: string }[];
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

// 管理ページに入れるのは role が "admin" のアカウントだけ。判定は
// ここ一箇所に置き、画面ごとに書き写さない。
export function isAdmin(roleName: string | null | undefined): boolean {
  return roleName === 'admin';
}

export type MediaAttachment = {
  id: string;
  type: string;
  url: string;
  preview_url?: string | null;
  description?: string | null;
  // Not Mastodon's shape — sukhi extension. The name the file was
  // uploaded under (server derives an extension-only fallback if the
  // browser never sent one). Absent on attachments uploaded before this.
  filename?: string | null;
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
  // ISO 639-1。本文の字を選ぶ手がかり(lang 属性)。無いこともある。
  language?: string | null;
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
  // Sukhi extension: how far the viewer's own post has got on its way out.
  // Only these three words; never which servers, never how many.
  delivery?: 'delivering' | 'delivered' | 'delayed' | null;
  // The same trip as a timeline. `percent` (steps of 10) only while sending.
  delivery_progress?: {
    stage: 'received' | 'signing' | 'queued' | 'sending' | 'done';
    percent: number | null;
  } | null;
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


export type Page<T> = { items: T[]; nextMaxId: string | null };

export type NotificationType =
  | 'favourite' | 'reblog' | 'follow' | 'follow_request' | 'mention'
  | 'status' | 'poll' | 'update' | 'reaction';

export type Notification = {
  id: string;
  type: NotificationType;
  created_at: string;
  account: Account;
  status?: Status | null;
  // gateway が、同じ種類の反応をまとめたとき。新しい順の全員(最初が `account`)。
  group?: { accounts: Account[] };
};

export type Context = { ancestors: Status[]; descendants: Status[] };
export type SearchResult = { accounts: Account[]; hashtags: Tag[]; statuses: Status[] };

export type TokenSet = {
  access_token: string;
  refresh_token?: string | null;
  scope: string;
  created_at: number;
};
