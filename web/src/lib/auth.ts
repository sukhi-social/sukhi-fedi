// OAuth client + token storage for the SPA.
//
// Talks to the same Mastodon-compatible endpoints sukhi-fedi already
// serves: POST /api/v1/apps to register a client, /oauth/authorize for
// the user-facing consent (server-rendered), /oauth/token to exchange
// or refresh.
//
// Three keys live in localStorage:
//   sf.client   — { client_id, client_secret, redirect_uri }
//   sf.token    — { access_token, refresh_token, scope, created_at }
//   sf.state    — single-use CSRF guard for the authorize redirect
//
// Server is reached relative to window.location.origin so the same
// build runs against any sukhi-fedi instance.

import { browser } from '$app/environment';

export type ClientCreds = {
  client_id: string;
  client_secret: string;
  redirect_uri: string;
  // 登録時に申告した scope。SCOPES 定数が広がったとき (例: read →
  // read write follow)、ここを見て古い credentials を捨てて再登録する。
  // 古いブラウザに置いてある creds は scopes が無いので、その場合も
  // 「古い・狭い」と見なして再登録する。
  scopes?: string;
};

export type TokenSet = {
  access_token: string;
  refresh_token?: string | null;
  scope: string;
  created_at: number;
};

const CLIENT_KEY = 'sf.client';
const TOKEN_KEY = 'sf.token';
const STATE_KEY = 'sf.state';
const DRAFT_KEY = 'sf.signup_draft';
// マルチアカウント: sf.token/sf.client(=「いま見ているアカウント」)は
// 一切さわらない ── 既存の呼び出し元(isLoggedIn/loadToken 直読み、
// .svelte 側に数十箇所)はこれまで通り。他に一度ログインしたことのある
// アカウントは sf.accounts(配列)へ。サーバ側の session_token(主)+
// session_tokens(側)とおなじ形。client(app登録)はアカウント間で
// 共有できるので、こちら側には持たせない。
const ACCOUNTS_KEY = 'sf.accounts';
// /login に「置き換えでなく追加」だと伝える一時フラグ。/app/callback が
// 読んで、戻ってきたトークンをどちらに仕舞うか決める。
const ADD_MODE_KEY = 'sf.adding_account';
// 書き込み (投稿・プロフィール編集) と follow を含む。読み取りだけの
// 古い token を持っている人は、書き込み API で 401/403 を踏むので
// その時点で clearToken → 再ログインで広い token を取り直す形。
//
// `push` は /api/v1/push/subscription 一式が要る scope。無いまま「知らせを
// 受け取る」を押すと、**ブラウザの許可(一度しか訊けない)を使ったあとで**
// サーバに 403 で断られる ── 手元からは「うまくいきませんでした」としか
// 見えない。広げたので、古い creds は下の scopes 比較で作り直される。
const SCOPES = 'read write follow push';

// password は API call の直前まで sessionStorage に乗るが、call の
// 直後(成功も失敗も)`clearSignupPassword` で消して、username +
// invite_code だけが残る形にしている。retry のとき再入力で済むのは
// 招待コードと ID、合言葉は毎回打ち直し ─ XSS で password が
// snapshot される窓を最小にするための取り決め。
// email_proof は /signup/email/confirm が返す署名つきの「この
// メールボックスを開けた」証明(20分有効)。サーバはこれ無しでは
// アカウントを作らない。password はレガシー・任意。
export type SignupDraft = {
  username: string;
  password?: string;
  invite_code: string;
  // 表示用(どのアドレスを確認したか)。サーバに渡るのは proof のほう。
  email?: string;
  email_proof?: string;
};

export function saveSignupDraft(d: SignupDraft): void {
  if (!browser) return;
  sessionStorage.setItem(DRAFT_KEY, JSON.stringify(d));
}

export function loadSignupDraft(): SignupDraft | null {
  if (!browser) return null;
  const raw = sessionStorage.getItem(DRAFT_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as SignupDraft;
  } catch {
    return null;
  }
}

// password だけ落とした draft で上書きする。/check が API を呼んだ
// 直後に必ず呼ぶ ─ 成功した場合はそのあと clearSignupDraft で全消し、
// 失敗時は username + invite_code が残るので、retry は合言葉だけ
// 打ち直してもらえばいい。
export function clearSignupPassword(): void {
  if (!browser) return;
  const d = loadSignupDraft();
  if (!d) return;
  const { password: _password, ...rest } = d;
  sessionStorage.setItem(DRAFT_KEY, JSON.stringify(rest));
}

export function clearSignupDraft(): void {
  if (!browser) return;
  sessionStorage.removeItem(DRAFT_KEY);
}

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

export function saveToken(t: TokenSet): void {
  if (!browser) return;
  localStorage.setItem(TOKEN_KEY, JSON.stringify(t));
}

export function clearToken(): void {
  if (!browser) return;
  localStorage.removeItem(TOKEN_KEY);
}

// ── マルチアカウント: 他に一度ログインしたことのあるアカウント ─────────

export type StoredAccount = { acct: string; token: TokenSet };

export function loadOtherAccounts(): StoredAccount[] {
  if (!browser) return [];
  const raw = localStorage.getItem(ACCOUNTS_KEY);
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? dedupeByAcct(parsed as StoredAccount[]) : [];
  } catch {
    return [];
  }
}

// AppNav の {#each otherAccounts as other (other.acct)} は key の重複を
// 許さない(each_key_duplicate で画面ごと落ちる)。書き込み側は毎回
// filter してから push しているので理屈上は重複しないはずだが、読む側
// でも黙って畳んでおく ── 表示は「何か古いのが残っていた」程度で済ませ、
// クラッシュにしない。後の方(新しい方)を残す。
function dedupeByAcct(list: StoredAccount[]): StoredAccount[] {
  const byAcct = new Map<string, StoredAccount>();
  for (const a of list) {
    if (a && typeof a.acct === 'string') byAcct.set(a.acct, a);
  }
  return [...byAcct.values()];
}

function saveOtherAccounts(list: StoredAccount[]): void {
  if (!browser) return;
  if (list.length === 0) localStorage.removeItem(ACCOUNTS_KEY);
  else localStorage.setItem(ACCOUNTS_KEY, JSON.stringify(list));
}

// どのアカウントも「いま見ている」自覚を持たない(sf.token がそう
// なので)── 切り替え・追加のたびに verify_credentials で問い直す。
// 呼び出し頻度は低い(切り替え操作そのものの中でしか呼ばない)ので、
// キャッシュしてまで避ける値ではない。
async function resolveAcct(token: TokenSet): Promise<string | null> {
  try {
    const res = await fetch('/api/v1/accounts/verify_credentials', {
      headers: { authorization: `Bearer ${token.access_token}` }
    });
    if (!res.ok) return null;
    const body = (await res.json()) as { acct?: string };
    return typeof body.acct === 'string' ? body.acct : null;
  } catch {
    return null;
  }
}

// 「いま見ている」アカウントを、sf.accounts の中の一つと入れ替える。
// 元「いま見ていた」方は、そのぶん sf.accounts へ移る。
export async function switchAccount(acct: string): Promise<void> {
  const target = loadOtherAccounts().find((a) => a.acct === acct);
  if (!target) throw new Error('not_found');

  const current = loadToken();
  let others = loadOtherAccounts().filter((a) => a.acct !== acct);

  if (current) {
    const currentAcct = await resolveAcct(current);
    if (currentAcct) {
      // push する前に必ず同じ acct を追い出す ── どこかに古いエントリが
      // 残っていたら(dedupeByAcct 参照)、そのまま push すると配列内で
      // 二重になって each_key_duplicate で画面が落ちる。
      others = others.filter((a) => a.acct !== currentAcct);
      others.push({ acct: currentAcct, token: current });
    }
  }

  saveOtherAccounts(others);
  saveToken(target.token);
}

// このブラウザから一つのアカウントだけ抜く。「いま見ている」方を抜いた
// ときは、残りの先頭を新しく「いま見ている」に格上げする(いなければ
// 完全ログアウトと同じ状態に)。トークンの失効はベストエフォート
// (signOutServer とおなじ考え方)。
export async function removeAccount(acct: string): Promise<void> {
  const current = loadToken();
  const currentAcct = current ? await resolveAcct(current) : null;

  if (current && currentAcct === acct) {
    await revokeToken(current);
    const [next, ...rest] = loadOtherAccounts();
    saveOtherAccounts(rest);
    if (next) saveToken(next.token);
    else clearToken();
    return;
  }

  const target = loadOtherAccounts().find((a) => a.acct === acct);
  if (target) await revokeToken(target.token);
  saveOtherAccounts(loadOtherAccounts().filter((a) => a.acct !== acct));
}

async function revokeToken(t: TokenSet): Promise<void> {
  const raw = localStorage.getItem(CLIENT_KEY);
  if (!raw) return;
  try {
    const c = JSON.parse(raw) as ClientCreds;
    await fetch('/oauth/revoke', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ token: t.access_token, client_id: c.client_id, client_secret: c.client_secret })
    });
  } catch {
    /* best-effort: local state is dropped by the caller regardless */
  }
}

// 「アカウントを追加」の入り口。/login(?mode=add)へ ── そこで別の
// 資格情報を入れてもらい、通ったら /oauth/authorize(サーバ側に
// もう主セッションがあるので、2アカウント以上ならピッカーが挟まる)
// → /app/callback → completeLogin が addOtherAccount で仕舞う。
export function startAddAccount(): void {
  if (!browser) return;
  localStorage.setItem(ADD_MODE_KEY, '1');
  const next = `${window.location.origin}/login?mode=add`;
  window.location.assign(next);
}

// dev で「ログイン後の見た目」を覗くための近道。web/.env.local に
// VITE_DEV_TOKEN を一行置いておくと(中身は何でもいい。本物のトークンが
// あればデータも出るし、`dev` みたいな偽物でも UI の骨格は見られる)、
// token を sf.token に置いて isLoggedIn() を true にする。本番ビルドでは
// import.meta.env.DEV が false なので丸ごと素通り ─ 漏れない。
//
// 偽トークンだと API は 401 を返すけれど、その下の redirectToLogin() は
// この devSession の間だけ黙る(下を参照)ので、ログイン画面に弾かれず
// navbar などログイン後の chrome をそのまま眺められる。
let devSession = false;

export function devAutoLogin(): void {
  if (!browser || !import.meta.env.DEV) return;
  const tok = (import.meta.env as Record<string, string | undefined>).VITE_DEV_TOKEN;
  if (!tok) return;
  devSession = true;
  if (!loadToken()) {
    saveToken({
      access_token: tok,
      scope: SCOPES,
      created_at: Math.floor(Date.now() / 1000)
    });
  }
}

// 同時に飛んだ複数の 401 が、それぞれ refresh を叩かないように
// 1 本の grant に束ねる。refresh token はサーバ側で rotate する
// (使うと revoke され新しいのが出る) ので、同じ古い token で並行に
// 叩くと片方が invalid_grant で負ける ─ その取りこぼしを防ぐ。
let refreshInFlight: Promise<TokenSet | null> | null = null;

// 保存ずみの refresh token で access token を取り直す (RFC 6749 §6)。
// 成功すれば新しい TokenSet を保存して返す。refresh token が無い・
// サーバに弾かれた等で取れなければ null ─ 呼び元 (api.ts) はそれを
// 見て login へ落とす。ここでは token は消さない (null = 「更新でき
// なかった」だけを伝え、捨てる判断は呼び元に委ねる)。
export function tryRefresh(): Promise<TokenSet | null> {
  if (refreshInFlight) return refreshInFlight;
  refreshInFlight = doRefresh().finally(() => {
    refreshInFlight = null;
  });
  return refreshInFlight;
}

async function doRefresh(): Promise<TokenSet | null> {
  if (!browser) return null;
  const current = loadToken();
  const rawClient = localStorage.getItem(CLIENT_KEY);
  if (!current?.refresh_token || !rawClient) return null;

  let client: ClientCreds;
  try {
    client = JSON.parse(rawClient) as ClientCreds;
  } catch {
    return null;
  }

  try {
    const res = await fetch('/oauth/token', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        grant_type: 'refresh_token',
        refresh_token: current.refresh_token,
        client_id: client.client_id,
        client_secret: client.client_secret
      })
    });
    if (!res.ok) return null;
    const t = (await res.json()) as TokenSet;
    saveToken(t);
    return t;
  } catch {
    return null;
  }
}

// セッションがもう戻せない (refresh token が無い・refresh も弾かれた)
// ときの行き先。token を捨てて、ホームの「入る」と同じ `/login` の
// 戸口へ送る。同期のハードナビゲーションなので、呼び元が保険で
// 走らせる client 側遷移 (goto('/')) より先に確定する。
export function redirectToLogin(): void {
  // dev の覗き見セッション中は弾かない。偽トークンの 401 でログイン画面へ
  // 飛ぶと、ログイン後の UI を見たいのに見られなくなるため ─ ここだけ黙る。
  if (devSession) return;
  clearToken();
  if (browser) window.location.assign('/login');
}

// RFC 7009 revoke: tell the server to invalidate the bearer token, then
// drop it locally. Best-effort — a failed/offline revoke still clears the
// local state, so sign-out always completes. Without this, "sign out" only
// removed the token from this browser while it stayed valid server-side.
export async function signOutServer(): Promise<void> {
  if (browser) {
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
        /* best-effort: local logout proceeds regardless */
      }
    }
  }
  clearToken();
}

export function isLoggedIn(): boolean {
  return !!loadToken();
}

// scope を「順番のゆらぎ」「重複」「空白の数」に寛容に比べる。
// "read write follow" と "follow read write" を同じものとして扱いたい。
function sameScopes(a: string | undefined, b: string): boolean {
  if (!a) return false;
  const norm = (s: string) =>
    s.trim().split(/\s+/).filter(Boolean).sort().join(' ');
  return norm(a) === norm(b);
}

async function loadOrRegisterClient(): Promise<ClientCreds> {
  if (!browser) throw new Error('no browser');
  const raw = localStorage.getItem(CLIENT_KEY);
  if (raw) {
    try {
      const cached = JSON.parse(raw) as ClientCreds;
      // 登録済み app の scope が、いま要求したい SCOPES と一致して
      // いればそのまま使う。一致しなければ、サーバ側の app 行は
      // 古い(狭い)ままなので /oauth/authorize で invalid_scope を
      // 食らう ─ creds を捨てて新しい app を登録しなおす。
      // 同じ理由で、scope 情報を持っていない古いキャッシュも捨てる。
      if (sameScopes(cached.scopes, SCOPES)) return cached;
      localStorage.removeItem(CLIENT_KEY);
      // 古い app に紐づく token も無効になるはずなので、ここで一緒に
      // 落としておく。再ログインで広い token を取り直してもらう。
      localStorage.removeItem(TOKEN_KEY);
    } catch {
      /* fallthrough — re-register */
    }
  }

  const redirect_uri = `${window.location.origin}/app/callback`;
  const res = await fetch('/api/v1/apps', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      client_name: 'sukhi-fedi web',
      redirect_uris: redirect_uri,
      scopes: SCOPES,
      website: window.location.origin
    })
  });

  if (!res.ok) {
    throw new Error(`app registration failed: ${res.status}`);
  }

  const body = await res.json();
  const creds: ClientCreds = {
    client_id: body.client_id,
    client_secret: body.client_secret,
    redirect_uri,
    scopes: SCOPES
  };
  localStorage.setItem(CLIENT_KEY, JSON.stringify(creds));
  return creds;
}

// Begin the Authorization Code flow. Generates a state, stores it,
// and navigates to /oauth/authorize. The server-rendered /login
// catches the unauthenticated case and bounces back here on success.
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

// Called on /app/callback. Verifies state, exchanges the code, persists
// the token. Throws on any check that fails.
//
// 「アカウントを追加」(startAddAccount 発、ADD_MODE_KEY で覚えている)
// のときは、新しいトークンで sf.token を上書きする前に、いま見ていた
// 方を sf.accounts へ退避する ── これで「追加」が「置き換え」になら
// ない。通常ログインでは今まで通り、ただ上書きするだけ。
export async function completeLogin(code: string, state: string): Promise<TokenSet> {
  const expected = localStorage.getItem(STATE_KEY);
  if (!expected || expected !== state) {
    throw new Error('state mismatch');
  }
  localStorage.removeItem(STATE_KEY);

  const adding = localStorage.getItem(ADD_MODE_KEY) === '1';
  localStorage.removeItem(ADD_MODE_KEY);

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

  if (!res.ok) {
    throw new Error(`token exchange failed: ${res.status}`);
  }

  const t = (await res.json()) as TokenSet;

  if (adding) {
    const previous = loadToken();
    // 「追加」で戻ってきた先が、実は前から知っていたアカウントだった
    // ケース(同じアカウントを選び直した/既に sf.accounts にあった方を
    // また選んだ)を、必ず一枚岩にする。newAcct を others から追い出して
    // おかないと、あとで switchAccount するときに同じ acct が配列内で
    // 二重になって画面が落ちる(each_key_duplicate、2026-08-08 実機で
    // 踏んだ)。
    const newAcct = await resolveAcct(t);
    let others = loadOtherAccounts();

    if (previous) {
      const prevAcct = await resolveAcct(previous);
      if (prevAcct && prevAcct !== newAcct) {
        others = others.filter((a) => a.acct !== prevAcct);
        others.push({ acct: prevAcct, token: previous });
      }
    }

    if (newAcct) others = others.filter((a) => a.acct !== newAcct);
    saveOtherAccounts(others);
  }

  saveToken(t);
  return t;
}

// メールを送る XHR は Anubis の CHALLENGE の内側に居る(botPolicies)。
// ページ(/login /signup)を開いた時点で cookie は立っているはずだが、
// フォームに長居して cookie が切れると、JSON の代わりに challenge の
// HTML が返ってくる。それを検知したら 'anubis' を投げ、呼び元が
// ページを読み直す(ページ自体の challenge が再走して cookie が戻る)。
function ensureJsonOrAnubis(res: Response): void {
  const ct = res.headers.get('content-type') ?? '';
  if (!ct.includes('application/json')) throw new Error('anubis');
}

// 加入前のメールボックス証明。request はコードを送り、confirm は
// 正しいコードと引き換えに署名つき email_proof を返す。これを
// signup() に渡す ─ password は無くてもいい(レガシー・任意)。
export async function requestSignupEmailCode(email: string): Promise<void> {
  const res = await fetch('/signup/email/request', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email })
  });
  ensureJsonOrAnubis(res);
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
  ensureJsonOrAnubis(res);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error((body as { error?: string })?.error ?? `signup_email_failed_${res.status}`);
  }
  return (body as { email_proof: string }).email_proof;
}

// Sign up via POST /api/v1/accounts. Called from `/check` AFTER Anubis
// has set its cookie ─ never directly from the form, so the PoW is
// always done before an account row is created.
export async function signup(
  input: Required<Pick<SignupDraft, 'username' | 'invite_code' | 'email_proof'>> &
    Pick<SignupDraft, 'password'>
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

  if (!ccRes.ok) {
    throw new Error(`client_credentials failed: ${ccRes.status}`);
  }

  const appToken = (await ccRes.json()) as TokenSet;

  const res = await fetch('/api/v1/accounts', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${appToken.access_token}`
    },
    body: JSON.stringify(input)
  });

  const body = await res.json().catch(() => ({}));

  if (!res.ok) {
    const reason = body?.error ?? `signup_failed_${res.status}`;
    const err = new Error(reason);
    // validation_failed は details に
    // `{username: ["は小文字英数字..."], ...}` が入っていることがある。
    // /check 側で field 名 + メッセージを出すために括って渡す。
    (err as Error & { details?: Record<string, string[]> }).details = body?.details;
    throw err;
  }

  saveToken(body as TokenSet);
  return body as TokenSet;
}

// 加入直後、署名つき email_proof を first-party セッション(cookie)に替える。
// メール加入を、パスワードログインと同じ地位に立たせる ─ cookie 専用の
// 管理面(パスキー・2FA・メール変更)が、二度目のログイン無しで使える。
// best-effort: ここで失敗しても、その画面に来たときメールの道で入りなおせる。
export async function establishSignupSession(emailProof: string): Promise<void> {
  const res = await fetch('/signup/session', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ email_proof: emailProof })
  });
  if (!res.ok) throw new Error(`signup_session_failed_${res.status}`);
}

// 一段目(パスワード or メールコード)が通ったあとのサーバの返事。
// cookie が立って終わりか、アプリ 2FA の二段目が要るかの二択。
export type FirstFactorResult = { ok: true } | { second_factor: 'totp'; pending: string };

// First-party credential login. POSTs username + password to `/login`,
// which validates them and sets the `session_token` cookie that
// `/oauth/authorize` later consumes. Cookie-based, NOT the OAuth bearer
// the rest of the SPA uses ─ this only opens the door; the caller then
// walks through `/check` (Anubis) → `/oauth/authorize` to get a token.
// アプリ 2FA が有効な人には cookie は立たず、`/login/totp` 用の
// pending トークンが返る ─ 呼び元が二段目の画面を出す。
//
// `add` = マルチアカウントの「追加」入り口から来た(サーバ側は
// mint_additional で受け止め、いまの主セッションを上書きしない)。
export async function loginWithPassword(
  username: string,
  password: string,
  add = false
): Promise<FirstFactorResult> {
  const res = await fetch('/login', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ username, password, ...(add ? { mode: 'add' } : {}) })
  });
  if (res.status === 401) throw new Error('invalid');
  if (!res.ok) throw new Error(`login_failed_${res.status}`);
  return (await res.json()) as FirstFactorResult;
}

// 二段目: /login で受け取った pending と、認証アプリの 6 桁。
// 通れば session_token cookie が立つ。`add` は loginWithPassword 参照。
export async function submitTotp(pending: string, code: string, add = false): Promise<void> {
  const res = await fetch('/login/totp', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ pending, code, ...(add ? { mode: 'add' } : {}) })
  });
  if (res.ok) return;
  const body = await res.json().catch(() => ({}));
  throw new Error(body?.error ?? `totp_failed_${res.status}`);
}

// メール認証コードでのログイン。request は、知らないアドレスにも
// 200 を返す(居る/居ないを言わない)ので、送った前提で次の画面へ。
export async function requestEmailLoginCode(email: string): Promise<void> {
  const res = await fetch('/login/email/request', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ email })
  });
  ensureJsonOrAnubis(res);
  if (res.ok) return;
  const body = await res.json().catch(() => ({}));
  throw new Error(body?.error ?? `email_request_failed_${res.status}`);
}

// `add` は loginWithPassword 参照(マルチアカウントの「追加」入り口)。
export async function loginWithEmailCode(
  email: string,
  code: string,
  add = false
): Promise<FirstFactorResult> {
  const res = await fetch('/login/email', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ email, code, ...(add ? { mode: 'add' } : {}) })
  });
  ensureJsonOrAnubis(res);
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body?.error ?? `email_login_failed_${res.status}`);
  }
  return (await res.json()) as FirstFactorResult;
}

// パスキーでのログイン。options → ブラウザの認証器 → submit まで
// 一息にやる。成功すれば cookie が立つ(2FA の二段目は無し ─
// 認証器の本人確認がその役)。`add` は loginWithPassword 参照。
export async function loginWithPasskey(add = false): Promise<void> {
  const { getPasskeyAssertion } = await import('./webauthn');

  const optRes = await fetch('/login/passkey/options', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: '{}'
  });
  if (!optRes.ok) throw new Error('passkey');
  const { ref, publicKey } = await optRes.json();

  const assertion = await getPasskeyAssertion(publicKey);

  const res = await fetch('/login/passkey', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ ref, ...assertion, ...(add ? { mode: 'add' } : {}) })
  });
  if (!res.ok) throw new Error('passkey');
}

// Set or change the signed-in account's password. Cookie-gated like
// /login (the session_token minted at login), not the bearer.
// 初回設定(これまであいことば無し)は current 不要で、サーバは
// {initial: true} を返しセッションも生きたまま。変更のときは全
// セッションが失効するので、呼び元は clearToken() して /login へ。
// Throws 'current' | 'mismatch' | 'short' | 'unauthorized'.
export async function changePassword(
  current: string,
  newPassword: string,
  confirm: string
): Promise<{ initial: boolean }> {
  const res = await fetch('/settings/password', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({
      current_password: current,
      new_password: newPassword,
      confirm_password: confirm
    })
  });
  if (res.ok) {
    const body = await res.json().catch(() => ({}));
    return { initial: !!(body as { initial?: boolean })?.initial };
  }
  const body = await res.json().catch(() => ({}));
  throw new Error(body?.error ?? `password_failed_${res.status}`);
}

// ── ログイン要素の管理 (settings/security と EmailNudge が使う) ──────
//
// 変更系は session cookie 専用(サーバ側の決め: bearer は第三者アプリ
// にも渡るから、ログイン要素には触らせない)。/auth/state だけは
// bearer でも読める ─ 加入直後(cookie がまだ無いことがある)でも
// ポップアップの出す/出さないを決められるように。

export type AuthState = {
  // false のときは cookie が無い(または切れた)ので、変更系を呼ぶ前に
  // もう一度 /login を通ってもらう必要がある。
  manageable: boolean;
  // 変更系がどのアカウントに効くか(session_token クッキーの持ち主)。
  // マルチアカウントで、いま bearer で見せているアカウントと違う
  // ことがある ─ settings/security ページがここを見て警告する。
  acct: string;
  email: string | null;
  email_verified: boolean;
  // false = パスワード無し(いまの標準)。要素を外す操作の本人確認は
  // password の代わりに reauth コード(メール)で行う。
  has_password: boolean;
  totp_enabled: boolean;
  totp_pending: boolean;
  passkeys: {
    id: number;
    nickname: string | null;
    created_at: string;
    last_used_at: string | null;
  }[];
};

// 要素を外す操作の本人確認。あいことばを持つ人は password、
// 持たない人は requestReauthCode() で届く 6 桁を reauth_code に。
export type Reauth = { password?: string; reauth_code?: string };

function bearerHeaders(): Record<string, string> {
  const t = loadToken();
  return t ? { authorization: `Bearer ${t.access_token}` } : {};
}

async function settingsPost(path: string, body: unknown): Promise<unknown> {
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify(body ?? {})
  });
  const parsed = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error((parsed as { error?: string })?.error ?? `failed_${res.status}`);
  }
  return parsed;
}

export async function fetchAuthState(): Promise<AuthState | null> {
  const res = await fetch('/auth/state', {
    credentials: 'same-origin',
    headers: bearerHeaders()
  });
  if (res.status === 401) return null;
  if (!res.ok) throw new Error(`auth_state_failed_${res.status}`);
  return (await res.json()) as AuthState;
}

// 本人確認コードを、登録ずみの確認済みメールへ送る。
export async function requestReauthCode(): Promise<void> {
  await settingsPost('/settings/reauth/request', {});
}

// メール登録/変更: コードを送る。すでに確認済みアドレスがある人が
// 別のアドレスへ変えるときだけ reauth(password か reauth_code)が要る。
export async function requestEmailCode(email: string, reauth?: Reauth): Promise<void> {
  await settingsPost('/settings/email/request', { email, ...(reauth ?? {}) });
}

export async function confirmEmailCode(code: string): Promise<void> {
  await settingsPost('/settings/email/confirm', { code });
}

export async function totpSetup(): Promise<{ secret: string; otpauth: string }> {
  return (await settingsPost('/settings/totp/setup', {})) as { secret: string; otpauth: string };
}

export async function totpEnable(code: string): Promise<void> {
  await settingsPost('/settings/totp/enable', { code });
}

export async function totpDisable(reauth: Reauth): Promise<void> {
  await settingsPost('/settings/totp/disable', reauth);
}

// レガシーのあいことば: 初回設定(currentなし) / 退役。変更は
// changePassword のまま。
export async function removePassword(password: string): Promise<void> {
  await settingsPost('/settings/password/remove', { password });
}

// パスキー登録: options → 認証器 → 登録、まで。
export async function registerPasskey(nickname: string): Promise<void> {
  const { createPasskey } = await import('./webauthn');

  const { ref, publicKey } = (await settingsPost('/settings/passkeys/options', {})) as {
    ref: string;
    publicKey: Parameters<typeof createPasskey>[0];
  };

  const payload = await createPasskey(publicKey);
  await settingsPost('/settings/passkeys', { ref, nickname, ...payload });
}

export async function deletePasskey(id: number, reauth: Reauth): Promise<void> {
  await settingsPost(`/settings/passkeys/${id}/delete`, reauth);
}

// いま入っている端末の一覧。current が「この端末」。新しい端末で
// 入ったときの「あたらしい端末でログインがありました」メールと対の、
// あとから見直すための窓。数字や煽りは出さない ─ ただの台帳。
export type Session = {
  id: number;
  // だいたいの場所(粗いIP)。'?' は分からなかったとき。
  ip: string;
  user_agent: string | null;
  created_at: string;
  last_seen_at: string | null;
  current: boolean;
};

export async function fetchSessions(): Promise<Session[]> {
  const res = await fetch('/settings/sessions', {
    credentials: 'same-origin',
    headers: bearerHeaders()
  });
  if (res.status === 401) return [];
  if (!res.ok) throw new Error(`sessions_failed_${res.status}`);
  const body = (await res.json()) as { sessions: Session[] };
  return body.sessions;
}

// 端末をログアウトさせる。要素を外すのと同じ本人確認(password か
// reauth コード)ごし。
export async function revokeSession(id: number, reauth: Reauth): Promise<void> {
  await settingsPost(`/settings/sessions/${id}/revoke`, reauth);
}

// ── 自分の古い投稿のお片づけ(アーカイブ) ───────────────────────────────
// ローカルにアーカイブ(行は残す)+ Delete を連合。preview は正直な
// 件数の下見(下書き = まだ何もしない)、execute は本人確認ごしの実行。
// 数字は煽りではなく、消える前に正直に見せるためのもの。
export type CleanupPreview = {
  older_than_days: number;
  // アーカイブされる件数(下見)。
  affected: number;
  // 守られて残るもの。
  protected: { pinned: number; direct: number };
};

export async function previewCleanup(olderThanDays: number): Promise<CleanupPreview> {
  return (await settingsPost('/settings/cleanup/preview', {
    older_than_days: olderThanDays
  })) as CleanupPreview;
}

// 実行: 本人確認(password か reauth コード)ごし。バックグラウンドの
// 常時トグルではなく、毎回はっきり押してもらう一回きりの動作。
export async function executeCleanup(
  olderThanDays: number,
  reauth: Reauth
): Promise<CleanupPreview> {
  return (await settingsPost('/settings/cleanup/execute', {
    older_than_days: olderThanDays,
    ...reauth
  })) as CleanupPreview;
}

// Navigate to the shared check page. Anubis challenges this path; the
// page picks up `intent` and finishes the flow on the other side.
//
// Single entry point used by all the doors ─ keeps the homepage's
// "入る"、signup の「作る」、login のメールタブが短く揃う。
// 'login-email' はメールコードでのログイン: コードの送信も入力も
// /check の上(= PoW の内側)で行われる。
// `add` = マルチアカウントの「追加」入り口(メールの道)。/check は
// これを ?mode=add として受け取り、その上の loginWithEmailCode/
// submitTotp 呼び出しへ引き継ぐ。
export function goToCheck(
  intent: 'login' | 'signup' | 'login-email',
  next?: string,
  add?: boolean
): void {
  const params = new URLSearchParams({ intent });
  if (next) params.set('next', next);
  if (add) params.set('mode', 'add');
  window.location.assign(`/check?${params.toString()}`);
}

// メールログインで /login → /check へ渡すアドレス。秘密ではない
// (コードはメール側に届く)が、URL に載せず session に置く。
const LOGIN_EMAIL_KEY = 'sf.login_email';

export function saveLoginEmail(email: string): void {
  if (!browser) return;
  sessionStorage.setItem(LOGIN_EMAIL_KEY, email);
}

export function loadLoginEmail(): string | null {
  if (!browser) return null;
  return sessionStorage.getItem(LOGIN_EMAIL_KEY);
}

export function clearLoginEmail(): void {
  if (!browser) return;
  sessionStorage.removeItem(LOGIN_EMAIL_KEY);
}
