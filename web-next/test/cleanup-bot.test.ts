// SPDX-License-Identifier: AGPL-3.0-or-later
// 古い投稿のお片づけ(下見 → 本人確認つきの実行)と、BOT の鍵(一回だけ見せる)。
// 偽の gateway(cookie 専用の口は session_token=mock が要る)と郵便局を子プロセスで立てて、端から端まで歩く。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5243;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4243', PUBLIC_ORIGIN: BASE },
    stdio: 'ignore'
  });
  for (let i = 0; i < 50; i++) {
    try {
      if ((await fetch(`${BASE}/login`)).status < 500) return;
    } catch {
      // まだ立っていない。
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('web-next did not start');
});

after(() => child?.kill());

let sid = '';
// gateway に入ったとき立つ cookie(session_token)は、ブラウザが持っている。signedIn=false で、持たない人。
async function go(path: string, init: RequestInit & { signedIn?: boolean; form?: Record<string, string> } = {}) {
  const { signedIn = true, form, ...rest } = init;
  const cookie = [sid, signedIn ? 'session_token=mock' : ''].filter(Boolean).join('; ');
  const res = await fetch(`${BASE}${path}`, {
    redirect: 'manual',
    ...rest,
    ...(form ? { method: 'POST', body: new URLSearchParams(form) } : {}),
    headers: { ...(cookie ? { cookie } : {}), origin: BASE, ...(form ? { 'content-type': 'application/x-www-form-urlencoded' } : {}), ...rest.headers }
  });
  const set = res.headers.get('set-cookie')?.split(';')[0];
  if (set?.startsWith('sukhi_sid=')) sid = set;
  return res;
}
const text = async (path: string, init?: Parameters<typeof go>[1]) => (await go(path, init)).text();
const log = async (): Promise<string[]> => (await fetch('http://localhost:4243/__mock/requests-log')).json();

test('設定の頁から、お片づけと鍵の頁へ行ける', async () => {
  const page = await text('/settings');
  assert.match(page, /href="\/settings\/cleanup"/);
  assert.match(page, /href="\/settings\/bot"/);
});

// ── お片づけ ──────────────────────────────────────────────
test('お片づけ: 最初は期間を選ぶだけ。実行のボタンは、まだ出ない', async () => {
  const page = await text('/settings/cleanup');
  assert.match(page, /<select name="days">/);
  assert.equal((page.match(/<option value="/g) ?? []).length, 5);
  assert.match(page, /<option value="365" selected>/);
  assert.doesNotMatch(page, /action="\/settings\/cleanup\/execute"/);
});

test('お片づけ: cookie の無い人には、フォームを出さずに「入りなおして」', async () => {
  const page = await text('/settings/cleanup?days=365', { signedIn: false });
  assert.match(page, /href="\/login"/);
  assert.doesNotMatch(page, /action="\/settings\/cleanup\/execute"/);
});

test('お片づけ: 件数を見ても、何も消えない。実行の頁には、本人確認の欄が付く', async () => {
  const page = await text('/settings/cleanup?days=365');
  assert.match(page, /12 件を削除します/);
  assert.match(page, /ピン留めの 2 件と、ダイレクトの 5 件/);
  assert.match(page, /action="\/settings\/cleanup\/execute"/);
  assert.match(page, /<input type="hidden" name="days" value="365"/);
  assert.match(page, /name="reauth_code"/);
  assert.match(page, /formaction="\/settings\/cleanup\/reauth"/);
  assert.equal((await log()).filter((l) => l.startsWith('cleanup/execute')).length, 0);
});

test('お片づけ: 決まった期間のほかは受けない(選びなおしの頁に戻る)', async () => {
  for (const bad of ['7', 'abc', '-1', '99999', '']) {
    const page = await text(`/settings/cleanup?days=${bad}`);
    assert.doesNotMatch(page, /action="\/settings\/cleanup\/execute"/, `days=${bad}`);
    assert.match(page, /<select name="days">/, `days=${bad}`);
  }
});

test('お片づけ: 消すものが 0 件なら、実行のボタンは出さない', async () => {
  const page = await text('/settings/cleanup?days=730');
  assert.match(page, /0 件を削除します/);
  assert.doesNotMatch(page, /action="\/settings\/cleanup\/execute"/);
});

test('お片づけ: コードを送る口は、期間を覚えたまま、同じ頁に戻る', async () => {
  const res = await go('/settings/cleanup/reauth', { form: { days: '365' } });
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/settings/cleanup?days=365');
  assert.match(await text('/settings/cleanup?days=365'), /コードを送りました/);
});

test('お片づけ: 本人確認が違えば実行されず、合えば受けつけて、始めた件数を見せる', async () => {
  const wrong = await go('/settings/cleanup/execute', { form: { days: '365', reauth_code: '000000' } });
  assert.equal(wrong.status, 422);
  const wrongBody = await wrong.text();
  assert.match(wrongBody, /class="error"/);
  assert.match(wrongBody, /12 件を削除します/); // もう一度、同じ頁(確認の段)
  assert.equal((await log()).filter((l) => l.startsWith('cleanup/execute')).length, 0);

  const done = await go('/settings/cleanup/execute', { form: { days: '365', reauth_code: '123456' } });
  assert.equal(done.status, 303);
  assert.equal(done.headers.get('location'), '/settings/cleanup?done=12');
  assert.deepEqual((await log()).filter((l) => l.startsWith('cleanup/execute')), ['cleanup/execute 365']);

  const after = await text('/settings/cleanup?done=12');
  assert.match(after, /12 件の削除を、はじめました/);
  assert.doesNotMatch(after, /action="\/settings\/cleanup\/execute"/);
});

test('お片づけ: 受けられない期間の実行は、gateway に届かない', async () => {
  const before = (await log()).length;
  const res = await go('/settings/cleanup/execute', { form: { days: '7', reauth_code: '123456' } });
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/settings/cleanup');
  assert.equal((await log()).length, before);
});

test('お片づけ: done に数字以外が来ても、そのまま頁に出さない', async () => {
  const page = await text('/settings/cleanup?done=%3Cscript%3E');
  assert.doesNotMatch(page, /<script>/);
  assert.match(page, /<select name="days">/);
});

// ── BOT の鍵 ──────────────────────────────────────────────
test('鍵: 名前と期限の欄。期限は 90 日が選ばれている', async () => {
  const page = await text('/settings/bot');
  assert.match(page, /action="\/settings\/bot"/);
  assert.match(page, /name="name"[^>]*maxlength="40"/);
  assert.equal((page.match(/<option value="/g) ?? []).length, 4);
  assert.match(page, /<option value="90" selected>/);
  assert.doesNotMatch(page, /class="token-once"/);
});

test('鍵: 発行すると、鍵はその返事にだけ載り、キャッシュさせない。預からない', async () => {
  const res = await go('/settings/bot', { form: { name: 'my-bot', days: '30' } });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  const body = await res.text();
  assert.match(body, /<code class="token-once">mock-key-my-bot-1<\/code>/);
  assert.match(body, /「my-bot」の鍵（30日で切れます）/);
  assert.match(body, /name="name"[^>]*value=""/); // 続けて同じ名前で出さないよう、欄は空に戻す
  assert.ok((await log()).includes('POST sukhi/tokens my-bot 30'));
  // もう一度開いても、鍵は出ない(セッションにも、flash にも置いていない)。
  assert.doesNotMatch(await text('/settings/bot'), /mock-key-my-bot-1/);
});

test('鍵: 期限は決まった数のほかは受けず、既定(90)に戻す', async () => {
  const res = await go('/settings/bot', { form: { name: 'odd-days', days: '9999' } });
  assert.equal(res.status, 200);
  assert.ok((await log()).includes('POST sukhi/tokens odd-days 90'));
});

test('鍵: 名前が空なら、gateway に送らず、やさしく断る', async () => {
  const before = (await log()).length;
  const res = await go('/settings/bot', { form: { name: '   ', days: '30' } });
  assert.equal(res.status, 422);
  assert.match(await res.text(), /class="error"/);
  assert.equal((await log()).length, before);
});

test('鍵: 回数制限(429)のときも、名前を残して、やさしく断る', async () => {
  const res = await go('/settings/bot', { form: { name: 'toomany', days: '7' } });
  assert.equal(res.status, 429);
  const body = await res.text();
  assert.match(body, /class="error"/);
  assert.match(body, /name="name"[^>]*value="toomany"/);
  assert.doesNotMatch(body, /class="token-once"/);
});

test('鍵: 名前の中の HTML は、そのまま出さない', async () => {
  const res = await go('/settings/bot', { form: { name: '<b>x</b>', days: '30' } });
  const body = await res.text();
  assert.doesNotMatch(body, /<b>x<\/b>/);
  assert.match(body, /&lt;b&gt;x&lt;\/b&gt;/);
});
