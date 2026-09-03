// スクショのための、にせのサーバ。
//
// 本物の gateway は立てない ── Playwright の route で `/api/...` を
// 途中で受け取って、ここに書いてある固定のデータを返す。だから
// 「箱が動いていないと絵が撮れない」にならないし、何度撮っても
// 同じ絵になる(時計も止めてある)。
//
// **中身は ja と ko の両方を持たせてある。** ここは i18n を目で見る
// ための道具なので、訳の入っていないデータだと、いちばん見たいものが
// 見えない。`*_i18n` に ko を入れて、韓国語の画面でちゃんと韓国語が
// 出るところまでを撮る。
//
// 知らない口が来たら黙って `[]` を返しつつ、名前を控える(run.mjs が
// 最後にまとめて出す) ── 撮れた絵が「空っぽなのに気づかれない」に
// ならないように。

// 止めた時計。「3 時間前」が毎回同じ絵になる。
export const NOW = new Date('2026-08-28T12:00:00+09:00');

const ago = (mins) => new Date(NOW.getTime() - mins * 60_000).toISOString();

// ── 人 ────────────────────────────────────────────────────────────

const person = (id, username, display, note, followers) => ({
  id,
  username,
  acct: username,
  display_name: display,
  note,
  avatar: '/hinata.png',
  avatar_url: '/hinata.png',
  url: `https://natadeco.com/@${username}`,
  followers_count: followers,
  following_count: 12,
  statuses_count: 48,
  bot: false
});

const hinata = person('1', 'hinata', 'ひなた', 'ここの看板です。AI が描いた絵です。', 132);
const kuro = person('2', 'kuro', 'くろ', 'お茶と、古い本。', 41);
const nabi = person('3', 'nabi', '나비', '부산에서. 디저트를 찾아다녀요.', 27);

const author = (p) => ({
  username: p.username,
  acct: p.acct,
  display_name: p.display_name,
  avatar_url: p.avatar_url
});

// ── デコ(板) ──────────────────────────────────────────────────────

const deco = (id, slug, name, nameKo, desc, descKo, kind, extra = {}) => ({
  id,
  slug,
  name,
  name_i18n: { ko: nameKo },
  description: desc,
  description_i18n: { ko: descKo },
  local_only: false,
  kind,
  topic: null,
  topic_by: null,
  topic_at: null,
  has_actor: true,
  minding: false,
  unread: false,
  notify: 'participating',
  post_count: 12,
  created_at: ago(60 * 24 * 30),
  ...extra
});

export const DECOS = [
  deco(1, 'chai', 'お茶の時間', '차 마시는 시간', '淹れたもの、いただいたもの。', '우려낸 것, 받은 것.', 'thread', {
    minding: true,
    unread: true,
    post_count: 34
  }),
  deco(2, 'yoru', 'よるのはなし', '밤의 이야기', '寝る前の、みじかい話。', '자기 전의, 짧은 이야기.', 'talk', {
    post_count: 108
  }),
  deco(3, 'machi', 'まちの記録', '동네 기록', '通りすがりに見たもの。', '지나가다 본 것.', 'thread', { post_count: 7 }),
  deco(4, 'tsukuru', 'つくったもの', '만든 것', '手を動かした話なら何でも。', '손을 움직인 이야기라면 뭐든지.', 'thread', {
    minding: true,
    post_count: 19
  })
];

// ── 書きこみ ──────────────────────────────────────────────────────

const post = (id, decoId, title, titleKo, body, bodyKo, who, mins, extra = {}) => ({
  id,
  deco_id: decoId,
  title,
  title_i18n: titleKo ? { ko: titleKo } : {},
  content: body,
  content_i18n: bodyKo ? { ko: bodyKo } : {},
  content_html: `<p>${body}</p>`,
  content_html_i18n: bodyKo ? { ko: `<p>${bodyKo}</p>` } : {},
  author: author(who),
  created_at: ago(mins),
  reply_count: 0,
  local_only: false,
  as_article: false,
  emojis: [],
  reactions: [],
  tags: [],
  folded: false,
  ...extra
});

// 板の棚。書かれた #タグ がそのまま並ぶ(多い順)。
export const TAGS = [
  { name: 'お茶', count: 3 },
  { name: 'ほうじ茶', count: 1 },
  { name: '海', count: 1 }
];

const REACTIONS = [
  { name: '🍵', count: 3, me: false },
  { name: '☺️', count: 1, me: true }
];

export const POSTS = [
  post(
    101,
    1,
    'ほうじ茶を、はじめて自分で焙じた',
    '호지차를, 처음으로 직접 볶아 봤어요',
    'フライパンで。台所じゅうがいい匂いになって、それだけで一日ぶんくらい、うれしかったです。',
    '프라이팬으로. 부엌 전체가 좋은 냄새로 가득 차서, 그것만으로 하루치만큼 기뻤어요.',
    kuro,
    35,
    { reply_count: 2, reactions: REACTIONS, tags: ['お茶', 'ほうじ茶'] }
  ),
  post(
    102,
    1,
    '기장 앞바다에서 마신 차',
    '기장 앞바다에서 마신 차',
    'ボトルに入れて持っていきました。風が強くて、すぐ冷めました。',
    '보온병에 담아 갔어요. 바람이 세서 금방 식었지만요.',
    nabi,
    190,
    { reply_count: 1 }
  ),
  post(
    103,
    1,
    null,
    null,
    '今日はなにも淹れませんでした。それも、お茶の時間だと思うことにします。',
    '오늘은 아무것도 우리지 않았어요. 그것도 차 마시는 시간이라고 생각하기로 했어요.',
    hinata,
    600
  )
];

const REPLIES = [
  post(
    201,
    1,
    null,
    null,
    'いい匂いのする失敗なら、何度でもしたいですね。',
    '좋은 냄새가 나는 실패라면, 몇 번이든 하고 싶네요.',
    hinata,
    20
  ),
  post(202, 1, null, null, '焙じ加減、どのくらいでした?', '볶는 정도는 어느 정도였어요?', nabi, 8)
];

export const POST_DETAIL = { ...POSTS[0], replies: REPLIES };

// 「話す板」の平らな流れ。
export const FLOW = [
  post(301, 2, null, null, 'おやすみなさい。', '잘 자요.', hinata, 3),
  post(302, 2, null, null, '今日は月がまるいです。', '오늘은 달이 둥글어요.', kuro, 14, {
    parent: { id: 301, author: author(hinata), excerpt: 'おやすみなさい。' }
  }),
  post(303, 2, null, null, '창문 열어 뒀어요. 시원해요.', '창문 열어 뒀어요. 시원해요.', nabi, 47)
];

// ── 友デコ(fediverse 側のタイムライン) ────────────────────────────

const status = (id, who, html, mins, extra = {}) => ({
  id,
  created_at: ago(mins),
  content: html,
  visibility: 'public',
  account: who,
  emojis: [],
  reactions: [],
  in_reply_to_id: null,
  ...extra
});

export const HOME = [
  status('1001', kuro, '<p>ひさしぶりに、古本屋の二階まで上がりました。</p>', 25),
  status('1002', nabi, '<p>영도에서 커피. 바다가 보이는 자리에 앉았어요.</p>', 120),
  status('1003', hinata, '<p>みなさん、今日はあたたかいものに出会えましたか。</p>', 300)
];

// ── 通知 ──────────────────────────────────────────────────────────

export const NOTICES = [
  {
    id: '9001',
    type: 'mention',
    created_at: ago(12),
    account: kuro,
    status: { id: '1001', content: '<p>お茶の話、続き書きました。</p>' }
  },
  { id: '9002', type: 'follow', created_at: ago(90), account: nabi, status: null },
  {
    id: '9003',
    type: 'favourite',
    created_at: ago(240),
    account: hinata,
    status: { id: '1003', content: '<p>今日はなにも淹れませんでした。</p>' }
  }
];

// ── ベランダ(よその板を覗く) ──────────────────────────────────────

export const VERANDA = {
  actor: {
    id: 'https://example.social/users/engawa',
    name: 'えんがわ',
    handle: '@engawa@example.social',
    summary: 'よそのおうちの、縁側です。',
    url: 'https://example.social/@engawa',
    icon: '/hinata.png',
    type: 'Group'
  },
  posts: [
    {
      id: 'v1',
      url: 'https://example.social/@engawa/1',
      title: '春の写真',
      content_html: '<p>とおくの山が、まだ白いままでした。</p>',
      author: 'えんがわ',
      published: ago(60 * 8)
    },
    {
      id: 'v2',
      url: 'https://example.social/@engawa/2',
      title: null,
      content_html: '<p>今日はここまで。</p>',
      author: 'えんがわ',
      published: ago(60 * 30)
    }
  ],
  truncated: true
};

// ── 口ごとの返事 ──────────────────────────────────────────────────
//
// 上から順に見て、最初に当たったものを返す。`when` は pathname だけを
// 見る(query は無視) ── 並びやページングは絵に効かないので。

const ROUTES = [
  ['/api/v1/deco', () => DECOS],
  [/^\/api\/v1\/deco\/veranda$/, () => VERANDA],
  [/^\/api\/v1\/deco\/posts\/\d+\/replies$/, () => REPLIES],
  [/^\/api\/v1\/deco\/posts\/\d+$/, () => POST_DETAIL],
  [/^\/api\/v1\/deco\/[^/]+\/posts$/, () => POSTS],
  [/^\/api\/v1\/deco\/[^/]+\/flow$/, () => FLOW],
  [/^\/api\/v1\/deco\/[^/]+\/tags$/, () => TAGS],
  [/^\/api\/v1\/deco\/([^/]+)$/, (m) => DECOS.find((d) => d.slug === m[1]) ?? DECOS[0]],
  ['/api/v1/timelines/home', () => HOME],
  ['/api/v1/notifications', () => NOTICES],
  ['/api/v1/markers', () => ({ notifications: { last_read_id: '9002' } })],
  ['/api/v1/accounts/verify_credentials', () => ({
    username: hinata.username,
    acct: hinata.acct,
    display_name: hinata.display_name,
    avatar_url: hinata.avatar_url,
    source: { note: hinata.note },
    role: { name: 'admin' }
  })],
  ['/api/v1/accounts/relationships', () => [{ id: '2', following: true, followed_by: true, requested: false }]],
  [/^\/api\/v1\/accounts\/([^/]+)\/statuses$/, () => HOME],
  [/^\/api\/v1\/accounts\/([^/]+)$/, (m) => [hinata, kuro, nabi].find((p) => p.id === m[1]) ?? kuro],
  ['/api/v2/search', () => ({ accounts: [kuro, nabi], statuses: [], hashtags: [] })],
  ['/api/v2/instance', () => ({ configuration: { vapid: { public_key: '' } } })],
  ['/auth/state', () => ({
    manageable: true,
    acct: hinata.acct,
    email: 'hinata@example.com',
    email_verified: true,
    has_password: false,
    totp_enabled: false,
    totp_pending: false,
    passkeys: [
      { id: 1, nickname: 'MacBook', created_at: ago(60 * 24 * 40), last_used_at: ago(60 * 3) },
      { id: 2, nickname: null, created_at: ago(60 * 24 * 9), last_used_at: null }
    ]
  })],
  [/^\/api\/v1\/deco\/[^/]+\/seen$/, () => ({ ok: true })],
  ['/login/email/request', () => ({ ok: true })],
  ['/login/email', () => ({ ok: true })],
  ['/login', () => ({ ok: true })],
  ['/signup/email/request', () => ({ ok: true })],
  ['/signup/email/confirm', () => ({ email_proof: 'mock-proof' })],
  ['/signup/session', () => ({ ok: true })],
  ['/oauth/token', () => ({ access_token: 'mock', scope: 'read write push', created_at: 0 })]
];

// 途中で受け取る道か。
//
// `/login` は **同じ綴りで二つある** ── GET はログインのページ(絵に
// 撮る相手)、POST は一段目を通す口(返事を作る相手)。だから method まで
// 見ないと、ページのほうを横取りしてしまう。`/settings` も同じ形で、
// `/settings` `/settings/security` はページ、`/settings/passkeys` などが口。
export function isApiPath(pathname, method) {
  // SvelteKit が遷移のたびに取る load の結果。口ではなく、描く側のもの。
  if (pathname.endsWith('/__data.json')) return false;
  if (pathname === '/login') return method === 'POST';
  return (
    pathname.startsWith('/api/') ||
    pathname === '/auth/state' ||
    pathname.startsWith('/oauth/') ||
    pathname.startsWith('/login/') ||
    pathname.startsWith('/signup/email/') ||
    pathname === '/signup/session' ||
    pathname.startsWith('/settings/passkeys') ||
    pathname.startsWith('/settings/reauth')
  );
}

export function answer(pathname) {
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

/**
 * ページに、止めた時計と、にせのサーバと、入っている状態を着せる。
 *
 * @param page       Playwright の Page
 * @param opts.lang  'ja' | 'ko'
 * @param opts.theme 'light' | 'dark'
 * @param opts.signedIn  ログインしている絵にするか
 * @param opts.seed  sessionStorage に置いておくもの(下書きなど)
 * @param unknown    知らない口を控える Set(呼び元が持つ)
 */
export async function installMocks(page, opts, unknown) {
  await page.clock.setFixedTime(NOW);

  await page.addInitScript(
    ({ lang, theme, signedIn, seed }) => {
      localStorage.setItem('nd.lang', lang);
      localStorage.setItem('nd.theme', theme);
      if (signedIn) {
        localStorage.setItem(
          'sf.token',
          JSON.stringify({ access_token: 'mock', scope: 'read write push', created_at: 0 })
        );
      } else {
        localStorage.removeItem('sf.token');
      }
      // ひなたの絵は、鍵が無ければ出る側が既定。既定に頼らず書いておく
      // ── いつか既定が変わっても、この一枚の絵は変わらないように。
      localStorage.setItem('nd.hinataHidden', '0');
      for (const [k, v] of Object.entries(seed ?? {})) sessionStorage.setItem(k, v);
    },
    { lang: opts.lang, theme: opts.theme, signedIn: opts.signedIn !== false, seed: opts.seed }
  );

  // matcher には URL しか渡らないので、method を見たいものは一度
  // 受け取ってから continue する(GET /login をここで素通しする道)。
  await page.route(
    (url) => isApiPath(url.pathname, 'POST') || isApiPath(url.pathname, 'GET'),
    async (route) => {
      const req = route.request();
      const pathname = new URL(req.url()).pathname;
      if (!isApiPath(pathname, req.method())) return route.continue();

      const body = answer(pathname);
      if (body === undefined) {
        unknown?.add(`${req.method()} ${pathname}`);
        return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
      }
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(body)
      });
    }
  );
}
