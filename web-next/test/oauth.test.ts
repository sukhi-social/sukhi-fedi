// SPDX-License-Identifier: AGPL-3.0-or-later
// 同意の頁(/oauth/authorize)。外のアプリが人を連れてくる所 ── アカウントを選ぶ・許可を聞く・うまく進めなかったとき。
// 何を見せるかは gateway の api が決める(GET/POST /api/v1/sukhi/oauth/authorize)。ここは、その決定を絵にして、
// ブラウザの session cookie だけを添えて聞く。偽の gateway は、cookie と問いの合言葉で四つの決定を出し分ける
// (mock/api-server.mjs)。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5260;
const BASE = `http://localhost:${PORT}`;
const MOCK = 'http://localhost:4260';
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: '', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4260', PUBLIC_ORIGIN: BASE },
    stdio: 'ignore'
  });
  for (let i = 0; i < 50; i++) {
    try {
      if ((await fetch(`${BASE}/login`)).ok) return;
    } catch {
      // まだ立っていない。
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('web-next did not start');
});

after(() => child?.kill());

const ask = (extra: Record<string, string> = {}) =>
  new URLSearchParams({
    client_id: 'app',
    redirect_uri: 'cx-test://done',
    scope: 'read write:statuses made-up',
    state: 's1',
    response_type: 'code',
    ...extra
  });
const get = (path: string, cookie = '', headers: Record<string, string> = {}) =>
  fetch(`${BASE}${path}`, { redirect: 'manual', headers: { ...(cookie ? { cookie } : {}), ...headers } });
const post = (path: string, body: Record<string, string>, cookie = '') =>
  fetch(`${BASE}${path}`, {
    method: 'POST',
    redirect: 'manual',
    headers: { 'content-type': 'application/x-www-form-urlencoded', origin: BASE, ...(cookie ? { cookie } : {}) },
    body: new URLSearchParams(body)
  });
const log = async (): Promise<string[]> => ((await (await fetch(`${MOCK}/__mock/requests-log`)).json()) as string[]).filter((l) => l.startsWith('oauth '));
const lastLog = async () => (await log()).at(-1) ?? '';

// cookie を一つだけ持ち回る小さなブラウザ(sukhi_sid だけ)。redirect は自分で辿る。
function browser() {
  let sid = '';
  return async (path: string, init: RequestInit = {}) => {
    const res = await fetch(`${BASE}${path}`, {
      redirect: 'manual',
      ...init,
      headers: { ...(sid ? { cookie: sid } : {}), origin: BASE, ...init.headers }
    });
    const set = res.headers.get('set-cookie')?.split(';')[0];
    if (set) sid = set;
    return res;
  };
}

test('入っていない人には、許可を聞かない。入りなおしへ', async () => {
  const res = await get(`/oauth/authorize?${ask()}`);
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/login?again=true');
});

test('入りなおした人は、外のアプリの問いに戻る。自分(この郵便局)が入るときの問いには、戻らない', async () => {
  const b = browser();
  const q = ask();
  assert.equal((await b(`/oauth/authorize?${q}`)).headers.get('location'), '/login?again=true');

  const first = await b('/login', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ method: 'password', username: 'a', password: 'b' }) });
  assert.equal(first.headers.get('location'), '/check?intent=login');
  const state = new URL((await b('/check?intent=login')).headers.get('location') ?? '', BASE).searchParams.get('state');
  assert.ok(state, '/check が、自分の OAuth を始める');

  // 戻りで、外のアプリの問い(元の query のまま)に帰る ── 古い state の自分の問いではなく。
  const back = await b(`/app/callback?code=c&state=${state}`);
  assert.equal(back.status, 303);
  assert.equal(back.headers.get('location'), `/oauth/authorize?${q}`);

  // 自分への戻り先(この郵便局の host)の問いは、next を置かない ── 入ったあとの /check が、新しい state でやりなおす。
  const own = browser();
  const ownAsk = ask({ redirect_uri: `${BASE}/app/callback`, state: 'old' });
  assert.equal((await own(`/oauth/authorize?${ownAsk}`)).headers.get('location'), '/login?again=true');
  await own('/login', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ method: 'password', username: 'a', password: 'b' }) });
  const s2 = new URL((await own('/check?intent=login')).headers.get('location') ?? '', BASE).searchParams.get('state');
  assert.equal((await own(`/app/callback?code=c&state=${s2}`)).headers.get('location'), '/');
});

test('外のアプリ: 許可を聞く頁。権限は、その人のことばで。form-action の無い CSP', async () => {
  const res = await get(`/oauth/authorize?${ask()}`, 'session_token=tok_1; sukhi_sid=not-for-the-gateway');
  assert.equal(res.status, 200);
  const page = await res.text();
  assert.match(page, /テストの道具/);
  assert.match(page, /<strong>読む<\/strong>/);
  assert.match(page, /<strong>投稿を書く<\/strong>/);
  assert.match(page, /<strong>made-up<\/strong> — この権限の説明は、まだ用意していません/);
  assert.match(page, /<form[^>]*method="post"[^>]*action="\/oauth\/authorize"/);
  for (const [name, value] of [['client_id', 'app'], ['redirect_uri', 'cx-test://done'], ['scope', 'read write:statuses made-up'], ['state', 's1']]) {
    assert.match(page, new RegExp(`name="${name}" value="${value}"`));
  }
  // WebKit が、フォームのあとの戻り先(custom scheme)にまで form-action を当てるので、この頁だけ立てない。
  const csp = res.headers.get('content-security-policy') ?? '';
  assert.match(csp, /frame-ancestors 'self'/);
  assert.doesNotMatch(csp, /form-action/);

  // gateway へは、ブラウザの session cookie だけ(sukhi_sid も、この郵便局の bearer も渡らない)。
  assert.match(await lastLog(), /cookie=\[session_token=tok_1\] bearer=no/);
});

test('ことば: cookie のことばで出る。知らない権限は、名前のまま', async () => {
  const page = await (await get(`/oauth/authorize?${ask()}`, 'session_token=t; sukhi_locale=ko')).text();
  assert.match(page, /<strong>읽기<\/strong>/);
  assert.match(page, /テストの道具/); // アプリの名前は api が持つ。訳さない
  const en = await (await get(`/oauth/authorize?${ask()}`, 'session_token=t; sukhi_locale=en')).text();
  assert.match(en, /<strong>Read<\/strong>/);
});

test('名前は、エスケープされる(クエリに入れた HTML は、ただの文字)', async () => {
  const page = await (await get(`/oauth/authorize?${ask({ redirect_uri: 'cx-test://done"><script>1</script>' })}`, 'session_token=t')).text();
  assert.doesNotMatch(page, /<script>1<\/script>/);
});

test('自分の host への戻り(web-next 自身)は、頁なしで通る。コードを持って帰る', async () => {
  const q = ask({ redirect_uri: `${BASE}/app/callback`, state: 'abc' });
  const res = await get(`/oauth/authorize?${q}`, 'session_token=tok_1');
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), `${BASE}/app/callback?code=first-party-code&state=abc`);
});

test('いくつも入っている人には、先にアカウントを選んでもらう。選ぶと、並べかえた cookie が渡って許可の頁へ', async () => {
  const cookie = 'session_token=tok_1; session_tokens=e30; sukhi_sid=x';
  const picker = await (await get(`/oauth/authorize?${ask()}`, cookie)).text();
  assert.match(picker, /@kuro/);
  assert.match(picker, /@nabi/);
  assert.doesNotMatch(picker, /テストの道具/);
  assert.match(await lastLog(), /cookie=\[session_token=tok_1; session_tokens=e30\]/);

  // 選ぶリンクは、同じ問いに choose=<id> を足したもの。
  const link = [...picker.matchAll(/href="(\/oauth\/authorize\?[^"]+)"/g)].map((m) => m[1].replaceAll('&amp;', '&'));
  assert.equal(link.length, 2);
  const chosen = new URL(link[1], BASE).searchParams;
  assert.equal(chosen.get('choose'), '2');
  assert.equal(chosen.get('client_id'), 'app');
  assert.equal(chosen.get('redirect_uri'), 'cx-test://done');

  const res = await get(link[1], cookie);
  assert.equal(res.status, 200);
  assert.match(await res.text(), /テストの道具/);
  const cookies = res.headers.getSetCookie();
  assert.ok(cookies.some((c) => c.startsWith('session_token=tok_2;')), '選んだ人を先頭にした cookie が、ブラウザへ渡る');
  assert.ok(cookies.some((c) => c.startsWith('session_tokens=tok_1;')));
});

test('同名の session_token が二つあっても、二つとも api に見てもらう', async () => {
  await get(`/oauth/authorize?${ask()}`, 'session_token=stale; session_token=live');
  assert.match(await lastLog(), /cookie=\[session_token=stale; session_token=live\]/);
});

test('「いいよ」: コードを持った戻り先へ。外のアプリの custom scheme でも、そのまま', async () => {
  const res = await post('/oauth/authorize', { client_id: 'app', redirect_uri: 'cx-test://done', scope: 'read', state: 's1' }, 'session_token=tok_1');
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), 'cx-test://done?code=posted-code&state=s1');
  assert.match(await lastLog(), /oauth POST client=app .*cookie=\[session_token=tok_1\] bearer=no/);
});

test('PKCE: 問いの challenge は、同意の form を通って、そのまま api へ。admin の権限は、ことばで見える', async () => {
  const ch = 'A'.repeat(43);
  const q = ask({ code_challenge: ch, code_challenge_method: 'S256', scope: 'admin:read admin:write' });
  const page = await (await get(`/oauth/authorize?${q}`, 'session_token=tok_1')).text();
  assert.match(page, new RegExp(`name="code_challenge" value="${ch}"`));
  assert.match(page, /name="code_challenge_method" value="S256"/);
  assert.match(page, /管理: 読む/);
  assert.doesNotMatch(page, /説明はまだ/);

  const res = await post('/oauth/authorize', { client_id: 'app', redirect_uri: 'cx-test://done', scope: 'admin:read', state: 's1', code_challenge: ch, code_challenge_method: 'S256' }, 'session_token=tok_1');
  assert.equal(res.status, 303);
  assert.match(await lastLog(), new RegExp(`oauth POST .* pkce=${ch}/S256`));

  // 付けなかった問いには、何も足さない。
  const plain = await (await get(`/oauth/authorize?${ask()}`, 'session_token=tok_1')).text();
  assert.doesNotMatch(plain, /code_challenge/);
});

test('「いいよ」を押すまでに、入っていたのが切れたら、入りなおしへ', async () => {
  const res = await post('/oauth/authorize', { client_id: 'app', redirect_uri: 'cx-test://done', scope: 'read', state: 's1' });
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/login?again=true');
});

test('「いいよ」は、同じ origin からだけ受ける', async () => {
  const res = await fetch(`${BASE}/oauth/authorize`, {
    method: 'POST',
    redirect: 'manual',
    headers: { 'content-type': 'application/x-www-form-urlencoded', origin: 'https://evil.example', cookie: 'session_token=tok_1' },
    body: new URLSearchParams({ client_id: 'app', redirect_uri: 'cx-test://done' })
  });
  assert.equal(res.status, 403);
});

test('うまく進められないとき: 理由つきの頁(責めない)。つながらないときは、そのことを', async () => {
  const unknown = await get(`/oauth/authorize?${ask({ client_id: 'ghost' })}`, 'session_token=t');
  assert.equal(unknown.status, 404);
  const page = await unknown.text();
  assert.match(page, /うまく進められませんでした/);
  assert.match(page, /<code>invalid_client<\/code>/);
  assert.match(page, /href="\/"/);

  const down = await get(`/oauth/authorize?${ask({ client_id: 'down' })}`, 'session_token=t');
  assert.equal(down.status, 503);
  assert.match(await down.text(), /つながりません/);
});

test('頁でない口(/oauth/token)は、これまでどおり gateway へ通す', async () => {
  const res = await fetch(`${BASE}/oauth/token`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
  assert.equal(res.status, 200);
  assert.equal(((await res.json()) as { access_token: string }).access_token, 'mock');
});
