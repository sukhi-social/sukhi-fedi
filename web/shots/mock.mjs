// スクショのための、にせのサーバ。
//
// gateway は立てない ── Playwright の route が `/api/...` を途中で
// 受け取って、ここに書いてある固定のデータを返す。時計も止めてある
// ので、何度撮っても同じ絵になる(差分で見られる)。
//
// **中身は ja と ko の両方が要る。** これは i18n を目で見るための道具
// なので、日本語しか無いデータだと、いちばん見たいところが見えない。
// 書く人を三人にして、一人は韓国語で書いている ── どちらの言語で開いて
// も「訳される画面」と「訳されない中身」が分かれて見える。
//
// 知らない口が来たら空を返しつつ名前を控える(run.mjs が最後に出す)
// ── 空っぽの絵に気づかないまま docs に貼らないように。

// 絵を撮るときは、時計を止めて同じ絵にする(run.mjs が page.clock で止める)。
// 本物のブラウザに出す偽サーバ(api-server.mjs)は、止められない時計の
// ほうに合わせる ── 起動の時刻を SUKHI_MOCK_NOW で渡すと、「何分前」が
// 起動したときを基準に並ぶ。
export const NOW = process.env.SUKHI_MOCK_NOW
  ? new Date(process.env.SUKHI_MOCK_NOW)
  : new Date('2026-08-28T12:00:00+09:00');

const ago = (mins) => new Date(NOW.getTime() - mins * 60_000).toISOString();

// ── 人 ────────────────────────────────────────────────────────────

const account = (id, acct, display, note, extra = {}) => ({
  id,
  username: acct.split('@')[0],
  acct,
  display_name: display,
  emojis: [],
  // build/ に在るもの。`/static/...` は本番のサーバが付ける前置きで、
  // 素の build には無い ── 割れた絵をドキュメントに貼らないように。
  avatar: '/avatar-default.svg',
  avatar_static: '/avatar-default.svg',
  header: null,
  header_static: null,
  url: `https://sukhi.f3liz.casa/@${acct}`,
  note,
  locked: false,
  bot: false,
  created_at: ago(60 * 24 * 400),
  followers_count: 84,
  following_count: 61,
  statuses_count: 512,
  fields: [],
  ...extra
});

export const ME = account('1', 'kuro', 'くろ', '<p>お茶と、古い本。ここの管理人です。</p>', {
  followers_count: 132,
  fields: [{ name: 'blog', value: '<a href="https://blog.atfedi.de">blog.atfedi.de</a>', verified_at: ago(60) }]
});
const NABI = account('2', 'nabi', '나비', '<p>부산에서. 디저트를 찾아다녀요.</p>', { followers_count: 47 });
const HINA = account('3', 'hinata@natadeco.com', 'ひなた', '<p>となりの星から来ました。</p>', {
  followers_count: 210
});

export const PEOPLE = [ME, NABI, HINA];

// ── 投稿 ──────────────────────────────────────────────────────────

const status = (id, who, content, mins, extra = {}) => ({
  id,
  created_at: ago(mins),
  content,
  emojis: [],
  spoiler_text: '',
  sensitive: false,
  visibility: 'public',
  in_reply_to_id: null,
  in_reply_to_account_id: null,
  account: who,
  media_attachments: [],
  tags: [],
  url: `https://sukhi.f3liz.casa/@${who.acct}/${id}`,
  reactions: [],
  favourited: false,
  favourites_count: 0,
  reblogged: false,
  reblogs_count: 0,
  bookmarked: false,
  poll: null,
  card: null,
  ...extra
});

const S1 = status('1001', ME, '<p>ほうじ茶を、はじめて自分で焙じました。台所じゅうがいい匂いです。</p>', 35, {
  favourites_count: 4,
  reblogs_count: 1,
  reactions: [
    { name: '🍵', count: 3, me: false },
    { name: '☺️', count: 1, me: true }
  ],
  tags: [{ name: 'ochado', url: 'https://sukhi.f3liz.casa/tags/ochado' }]
});

const S2 = status('1002', NABI, '<p>영도에서 커피. 바다가 보이는 자리에 앉았어요.</p>', 120, {
  favourited: true,
  favourites_count: 2
});

const S3 = status('1003', HINA, '<p>みなさん、今日はあたたかいものに出会えましたか。</p>', 300, {
  reblogs_count: 3
});

// 引用と、たたまれたもの(CW)。どちらも画面の形が変わるので、一枚ずつ。
const S4 = status('1004', NABI, '<p>이 글, 좋았어요.</p>', 400, { quote: S1 });
const S5 = status('1005', ME, '<p>庭に、蜂がたくさん来ていました。</p>', 700, {
  spoiler_text: '虫の話',
  sensitive: true
});

// ブースト(包むほうの account がブーストした人)。
const S6 = status('1006', ME, '', 800, { reblog: S3 });

const ARTICLE = status(
  '2001',
  HINA,
  '<h2>板をつくるということ</h2><p>掲示板は、タイムライン とちがって「場所」があります。' +
    'その場所に、名前と、説明と、はじめの一枚が要ります。</p><p>ここでは、それをデコと呼んでいます。</p>',
  60 * 26,
  { title: '板をつくるということ' }
);

export const HOME = [S1, S2, S3, S4, S5, S6];
export const CONTEXT = {
  ancestors: [],
  descendants: [
    status('1101', HINA, '<p>いい匂いのする失敗なら、何度でもしたいですね。</p>', 20, {
      in_reply_to_id: '1002',
      in_reply_to_account_id: '2'
    }),
    status('1102', ME, '<p>볶는 정도는 어느 정도였어요?</p>', 8, {
      in_reply_to_id: '1002',
      in_reply_to_account_id: '2'
    })
  ]
};

// ── 通知・会話・その他 ────────────────────────────────────────────

export const NOTIFICATIONS = [
  { id: '9001', type: 'mention', created_at: ago(12), account: NABI, status: S2 },
  { id: '9002', type: 'favourite', created_at: ago(60), account: HINA, status: S1 },
  { id: '9003', type: 'follow', created_at: ago(200), account: NABI, status: null },
  { id: '9004', type: 'reblog', created_at: ago(400), account: HINA, status: S1 }
];

const DM = (id, who, content, mins) =>
  status(id, who, content, mins, { visibility: 'direct' });

export const CONVERSATIONS = [
  {
    id: 'c1',
    unread: true,
    accounts: [NABI],
    last_status: DM('3002', NABI, '<p>내일 시간 괜찮으세요?</p>', 18)
  },
  {
    id: 'c2',
    unread: false,
    accounts: [HINA],
    last_status: DM('3010', HINA, '<p>ありがとうございました。</p>', 60 * 20)
  }
];

export const CONVERSATION_STATUSES = [
  DM('3001', ME, '<p>こんばんは。あしたのこと、決めましょうか。</p>', 40),
  DM('3002', NABI, '<p>내일 시간 괜찮으세요?</p>', 18)
];

// クリップ(自分あて DM)。ピンは既存のリアクション機構を借りている。
export const CLIP_CONVERSATIONS = [{ id: 'c0', unread: false, accounts: [], last_status: null }];

export const LISTS = [
  {
    id: '1',
    title: 'お茶の人',
    replies_policy: 'list',
    exclusive: false,
    filter_only_media: false,
    filter_hide_boosts: false,
    filter_hide_sensitive: false,
    filter_keyword: '',
    filter_replies: 'all'
  },
  {
    id: '2',
    title: '조용한 사람들',
    replies_policy: 'followed',
    exclusive: true,
    filter_only_media: false,
    filter_hide_boosts: true,
    filter_hide_sensitive: false,
    filter_keyword: '',
    filter_replies: 'to_me'
  }
];

export const ANNOUNCEMENTS = [
  {
    id: 'a1',
    content: '<p>8/30(日)の午前に、しずかな時間をとってお手入れをします。少しのあいだ止まります。</p>',
    starts_at: null,
    ends_at: null,
    published_at: ago(60 * 5),
    read: false
  }
];

export const MAP = {
  at: NOW.toISOString(),
  streams: {
    outbox: { seq: 128_401, held: 0 },
    outbox_dlq: { seq: 12, held: 2 },
    events: { seq: 51_233, held: 0 }
  },
  notes_24h: { local: 34, remote: 1_208 },
  deliveries_24h: 892,
  peers: [
    { domain: 'natadeco.com', notes_24h: 210 },
    { domain: 'hackers.pub', notes_24h: 96 },
    { domain: 'mastodon.social', notes_24h: 61 },
    { domain: 'misskey.io', notes_24h: 24 }
  ]
};

const AUTH_STATE = {
  manageable: true,
  acct: ME.acct,
  email: 'kuro@example.com',
  email_verified: true,
  has_password: false,
  totp_enabled: true,
  totp_pending: false,
  passkeys: [
    { id: 1, nickname: 'MacBook', created_at: ago(60 * 24 * 40), last_used_at: ago(60 * 3) },
    { id: 2, nickname: null, created_at: ago(60 * 24 * 9), last_used_at: null }
  ]
};

const TERMS_HTML =
  '<h1>利用規約</h1><p>ここは、しずかに過ごすための場所です。' +
  '書いたものは、あなたのものです。</p><h2>やめてほしいこと</h2>' +
  '<p>だれかを傷つけること。</p>';

// ── 口ごとの返事 ──────────────────────────────────────────────────

const statusById = (id) => [...HOME, ARTICLE].find((s) => s.id === id) ?? (id === '2001' ? ARTICLE : S1);

// 押したあとの姿。数も、ひとつ動かす。
const PRESS = {
  favourite: { favourited: true, favourites_count: +1 },
  unfavourite: { favourited: false, favourites_count: -1 },
  reblog: { reblogged: true, reblogs_count: +1 },
  unreblog: { reblogged: false, reblogs_count: -1 },
  bookmark: { bookmarked: true },
  unbookmark: { bookmarked: false },
  pin: { pinned: true },
  unpin: { pinned: false }
};

function pressed(s, verb) {
  const next = { ...s };
  for (const [key, to] of Object.entries(PRESS[verb])) {
    next[key] = typeof to === 'number' ? Math.max(0, (s[key] ?? 0) + to) : to;
  }
  return next;
}

const ROUTES = [
  ['/api/v1/accounts/verify_credentials', () => ({ ...ME, source: { note: 'お茶と、古い本。', fields: [] } })],
  ['/api/v1/accounts/migration', () => ({ aliases: ['https://old.example/users/kuro'], moved_to: null })],
  ['/api/v1/accounts/lookup', () => ME],
  ['/api/v1/accounts/relationships', () =>
    PEOPLE.map((p) => ({ id: p.id, following: p.id !== '1', followed_by: true, requested: false }))],
  [/^\/api\/v1\/accounts\/([^/]+)\/statuses$/, () => HOME.slice(0, 4)],
  [/^\/api\/v1\/accounts\/([^/]+)\/(followers|following)$/, () => PEOPLE],
  [/^\/api\/v1\/accounts\/([^/]+)$/, (m) => PEOPLE.find((p) => p.id === m[1]) ?? ME],
  ['/api/v1/announcements', () => ANNOUNCEMENTS],
  ['/api/v1/custom_emojis', () => []],
  ['/api/v1/follow_invites', () => [{ code: 'warm-code' }]],
  ['/api/v1/follow_requests', () => [NABI]],
  ['/api/v1/blocks', () => []],
  ['/api/v1/mutes', () => [HINA]],
  ['/api/v1/bookmarks', () => [S1, S3]],
  ['/api/v1/favourites', () => [S2]],
  ['/api/v1/conversations', () => CONVERSATIONS],
  [/^\/api\/v1\/conversations\/([^/]+)\/statuses$/, () => CONVERSATION_STATUSES],
  ['/api/v1/lists', () => LISTS],
  // 全員を入れると、どの投稿にもリストの札が付いて「そういう画面」に
  // 見えてしまう。一人だけ入れて、札が付く人と付かない人を並べる。
  [/^\/api\/v1\/lists\/([^/]+)\/accounts$/, () => [NABI]],
  [/^\/api\/v1\/lists\/([^/]+)$/, (m) => LISTS.find((l) => l.id === m[1]) ?? LISTS[0]],
  ['/api/v1/notifications', () => NOTIFICATIONS],
  [/^\/api\/v1\/timelines\/(home|public)$/, () => HOME],
  [/^\/api\/v1\/timelines\/(tag|list)\/[^/]+$/, () => HOME.slice(0, 3)],
  [/^\/api\/v1\/statuses\/([^/]+)\/context$/, () => CONTEXT],
  // ☆ や 🔁 を押したら、その投稿が「押した後の姿」で返る。
  // 返事が空だと、画面は押す前に戻ってしまい、壊れて見える。
  [/^\/api\/v1\/statuses\/([^/]+)\/(favourite|unfavourite|reblog|unreblog|bookmark|unbookmark|pin|unpin)$/, (m) =>
    pressed(statusById(m[1]), m[2])],
  [/^\/api\/v1\/statuses\/([^/]+)$/, (m) => statusById(m[1])],
  // 投稿は、書いたものではなく、決まった一件が返る(中身は見ない)。
  ['/api/v1/statuses', () => status('9100', ME, '<p>(mock) 投稿を受け取りました。</p>', 0)],
  ['/api/i/notes/drafts', () => NO_CONTENT],
  // 「読んだ」は、その会話そのものを返す ── ページはこの返り値を
  // 会話として持つので、空の {} を返すと相手の名前で落ちる。
  [/^\/api\/v1\/conversations\/([^/]+)\/read$/, (m) =>
    CONVERSATIONS.find((c) => c.id === m[1]) ?? CLIP_CONVERSATIONS[0]],
  ['/api/v1/push/subscription', () => null],
  ['/api/v2/search', () => ({ accounts: [NABI, HINA], hashtags: [{ name: 'ochado', url: '' }], statuses: [S1] })],
  ['/api/v2/instance', () => ({
    domain: 'sukhi.f3liz.casa',
    title: 'sukhi.f3liz.casa',
    description: 'しずかな星。',
    configuration: { vapid: { public_key: '' } },
    registrations: { enabled: true, approval_required: true }
  })],
  ['/api/map', () => MAP],
  [/^\/api\/v1\/invite\/[^/]+$/, () => ({
    valid: true,
    issuer_handle: '@hinata@natadeco.com',
    issuer_display_name: 'ひなた'
  })],
  ['/auth/state', () => AUTH_STATE],
  ['/settings/sessions', () => ({
    sessions: [
      { id: '1', current: true, user_agent: 'Firefox / macOS', ip: '203.0.113.7', last_seen_at: ago(2) },
      { id: '2', current: false, user_agent: 'Safari / iPhone', ip: '203.0.113.9', last_seen_at: ago(60 * 30) }
    ]
  })],
  ['/login/email/request', () => ({ ok: true })],
  ['/login/email', () => ({ ok: true })],
  ['/login', () => ({ ok: true })],
  ['/signup/email/request', () => ({ ok: true })],
  ['/signup/email/confirm', () => ({ email_proof: 'mock-proof' })],
  ['/signup/session', () => ({ ok: true })],
  ['/oauth/token', () => ({ access_token: 'mock', scope: 'read write push', created_at: 0 })]
];

// 「中身は無い」と答える印。`getServerDraft` は 204 を「下書きはまだ
// 無い」と読むので、空の配列を返すと `.text.trim()` で落ちる ── 空を
// 返すのと、無いと答えるのは、違うことだった(2026-08-28 に踏んだ)。
export const NO_CONTENT = Symbol('no-content');

// SSE / WebTransport。開きっぱなしの口は、絵が「まだ読み込み中」で
// 固まる原因になる ── `retry` を一日にして、ブラウザに繋ぎ直させない。
const STREAM_BODY = 'retry: 86400000\n\n';

export function isApiPath(pathname, method) {
  // `/login` と `/settings/password` は同じ綴りで二つある ── GET は
  // ページ(絵に撮る相手)、POST は口(返事を作る相手)。
  // `/settings/cleanup` も同じ ── ページはそれ自身、口は `/preview` `/execute`。
  if (pathname === '/login' || pathname === '/settings/password') return method === 'POST';
  return (
    pathname.startsWith('/api/') ||
    pathname === '/auth/state' ||
    pathname.startsWith('/oauth/') ||
    pathname.startsWith('/login/') ||
    pathname.startsWith('/signup/email/') ||
    pathname === '/signup/session' ||
    pathname.startsWith('/settings/sessions') ||
    pathname.startsWith('/settings/passkeys') ||
    pathname.startsWith('/settings/reauth') ||
    pathname.startsWith('/settings/cleanup/') ||
    pathname.startsWith('/terms') ||
    pathname.startsWith('/privacy')
  );
}

function answer(pathname) {
  for (const [pat, make] of ROUTES) {
    if (typeof pat === 'string') {
      if (pathname === pat) return make();
    } else {
      const m = pathname.match(pat);
      if (m) return make(m);
    }
  }
  return undefined;
}

// 返事を決めるのは、ここ一か所。Playwright の route(installMocks)も、
// 本物の HTTP サーバ(api-server.mjs)も、これを呼ぶ ── どちらにも
// 同じデータと同じ形の返事が出る。
//
//   null              … この口はモックのものではない(素通し / 404)
//   { status, contentType, body, keepOpen?, unknown? }
//     keepOpen = 開いたまま保つべき口(SSE)。unknown = 返事を用意していない口(空で返した)
export function respond(pathname, method) {
  if (!isApiPath(pathname, method)) return null;

  if (pathname.startsWith('/api/v1/streaming') || pathname === '/api/wt') {
    return { status: 200, contentType: 'text/event-stream', body: STREAM_BODY, keepOpen: true };
  }
  if (pathname.startsWith('/terms') || pathname.startsWith('/privacy')) {
    return { status: 200, contentType: 'text/html; charset=utf-8', body: TERMS_HTML };
  }

  const body = answer(pathname);
  if (body === NO_CONTENT) return { status: 204, contentType: undefined, body: '' };
  if (body === undefined) {
    return { status: 200, contentType: 'application/json', body: '[]', unknown: true };
  }
  return { status: 200, contentType: 'application/json', body: JSON.stringify(body) };
}

export async function installMocks(page, opts, unknown) {
  await page.clock.setFixedTime(NOW);

  await page.addInitScript(
    ({ locale, signedIn }) => {
      localStorage.setItem('sukhi.locale', locale);
      if (signedIn) {
        localStorage.setItem(
          'sf.token',
          JSON.stringify({ access_token: 'mock', scope: 'read write push', created_at: 0 })
        );
      } else {
        localStorage.removeItem('sf.token');
      }
    },
    { locale: opts.lang, signedIn: opts.signedIn !== false }
  );

  // 下書きなど、ページの手前で置いておくもの。
  if (opts.seed) {
    await page.addInitScript((seed) => {
      for (const [k, v] of Object.entries(seed)) sessionStorage.setItem(k, v);
    }, opts.seed);
  }

  // streaming は WebSocket なので `page.route` では拾えない(あちらは
  // HTTP だけ)。素通しにすると静的サーバが index.html を 200 で返して
  // handshake が壊れ、アプリが繋ぎ直しつづけて画面が落ち着かない
  // ── ここで受けて、開いたまま黙っている(いちばん静かな「繋がって
  // いる」)。
  await page.routeWebSocket(/\/api\/v1\/streaming/, () => {});

  await page.route(
    (url) => isApiPath(url.pathname, 'POST') || isApiPath(url.pathname, 'GET'),
    async (route) => {
      const req = route.request();
      const pathname = new URL(req.url()).pathname;
      const out = respond(pathname, req.method());
      if (!out) return route.continue();
      if (out.unknown) unknown?.add(`${req.method()} ${pathname}`);
      // route.fulfill は応答を閉じるしかない(開いたままの SSE は api-server.mjs のほう)。
      return route.fulfill({ status: out.status, contentType: out.contentType, body: out.body });
    }
  );
}
