// SPDX-License-Identifier: AGPL-3.0-or-later
// ログインと安全・あいことば・引っ越し。偽の gateway(cookie 専用の口は session_token=mock が要る)と郵便局を
// 子プロセスで立てて、頁を開き、本人確認つきの操作を、端から端まで歩く。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5192;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4192', PUBLIC_ORIGIN: BASE },
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
    ...(form ? { method: 'POST', body: new URLSearchParams(form), headers: { 'content-type': 'application/x-www-form-urlencoded' } } : {}),
    headers: { ...(cookie ? { cookie } : {}), origin: BASE, ...(form ? { 'content-type': 'application/x-www-form-urlencoded' } : {}), ...rest.headers }
  });
  const set = res.headers.get('set-cookie')?.split(';')[0];
  if (set?.startsWith('sukhi_sid=')) sid = set;
  return res;
}
const text = async (path: string, init?: Parameters<typeof go>[1]) => (await go(path, init)).text();

test('メールのアドレスは、Cloudflare に書き換えられないよう email_off で囲む', async () => {
  const page = await text('/settings/security');
  assert.match(page, /<!--email_off-->[\s\S]*kuro@example\.com[\s\S]*<!--\/email_off-->/);
});

test('設定の頁から、ログインと安全・引っ越しへ行ける', async () => {
  const page = await text('/settings');
  assert.match(page, /href="\/settings\/security"/);
  assert.match(page, /href="\/settings\/migration"/);
});

test('cookie が無い人には、フォームを出さずに「入りなおして」', async () => {
  const page = await text('/settings/security', { signedIn: false });
  assert.match(page, /href="\/login"/);
  assert.doesNotMatch(page, /action="\/settings\/security\/email"/);
});

test('開く: メール・パスキー・端末が並び、あいことばの無い人には確認コードの欄', async () => {
  const page = await text('/settings/security');
  assert.match(page, /kuro@example\.com/);
  assert.match(page, /ノート PC/);
  assert.match(page, /Safari · iOS/);
  // この端末には「出す」操作を置かない(ほかの端末だけ)。
  assert.doesNotMatch(page, /sessions\/1\/revoke/);
  assert.match(page, /sessions\/2\/revoke/);
  assert.match(page, /name="reauth_code"/);
  assert.doesNotMatch(page, /type="password" name="password"/);
  assert.match(page, /data-passkey-add/);
});

test('メールを変える: 本人確認が違えば止まり、通ればコードの欄 → 確認', async () => {
  const bad = await go('/settings/security/email', { form: { email: 'new@example.com', reauth_code: '000000' } });
  assert.equal(bad.status, 422);
  assert.match(await bad.text(), /class="error"/);

  const sent = await go('/settings/security/email', { form: { email: 'new@example.com', reauth_code: '123456' } });
  assert.equal(sent.status, 303);
  const loc = sent.headers.get('location')!;
  assert.match(loc, /step=email/);
  assert.match(await text(loc), /action="\/settings\/security\/email\/confirm"/);

  const wrong = await go('/settings/security/email/confirm', { form: { code: '999999' } });
  assert.equal(wrong.status, 422);
  assert.match(await wrong.text(), /action="\/settings\/security\/email\/confirm"/);

  const done = await go('/settings/security/email/confirm', { form: { code: '123456' } });
  assert.equal(done.status, 303);
  assert.match(await text('/settings/security'), /new@example\.com/);
});

test('確認コードを送る: 押した折りたたみを開いて戻る', async () => {
  const res = await go('/settings/security/reauth', { form: { open: 'sess-2' } });
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/settings/security?open=sess-2');
  assert.match(await text('/settings/security?open=sess-2'), /<details open>/);
});

test('二段階認証: QR が出て、コードが違えば同じ QR のまま、合えばオン → 本人確認でオフ', async () => {
  const setup = await go('/settings/security/totp/setup', { form: {} });
  assert.equal(setup.status, 200);
  const page = await setup.text();
  assert.match(page, /<svg/);
  assert.match(page, /JBSWY3DPEHPK3PXP/);

  const form = { secret: 'JBSWY3DPEHPK3PXP', otpauth: 'otpauth://totp/kuro@sukhi.test?secret=JBSWY3DPEHPK3PXP' };
  const wrong = await go('/settings/security/totp/enable', { form: { ...form, code: '000000' } });
  assert.equal(wrong.status, 422);
  assert.match(await wrong.text(), /JBSWY3DPEHPK3PXP/);

  const on = await go('/settings/security/totp/enable', { form: { ...form, code: '123456' } });
  assert.equal(on.status, 303);
  assert.match(await text('/settings/security'), /action="\/settings\/security\/totp\/disable"/);

  const refused = await go('/settings/security/totp/disable', { form: { reauth_code: '000000' } });
  assert.equal(refused.status, 422);
  const off = await go('/settings/security/totp/disable', { form: { reauth_code: '123456' } });
  assert.equal(off.status, 303);
  assert.match(await text('/settings/security'), /action="\/settings\/security\/totp\/setup"/);
});

test('パスキー: 登録の二つの口は JSON、消すのは本人確認つき', async () => {
  const opt = await go('/settings/security/passkeys/options', { method: 'POST', body: '{}', headers: { 'content-type': 'application/json' } });
  assert.equal(opt.status, 200);
  assert.ok((await opt.json()).publicKey.challenge);

  const reg = await go('/settings/security/passkeys', {
    method: 'POST',
    body: JSON.stringify({ ref: 'r1', nickname: 'スマホ', attestation_object: 'x', client_data_json: 'y' }),
    headers: { 'content-type': 'application/json' }
  });
  assert.equal(reg.status, 200);
  assert.match(await text('/settings/security'), /スマホ/);

  assert.equal((await go('/settings/security/passkeys/1/delete', { form: { reauth_code: '0' } })).status, 422);
  assert.equal((await go('/settings/security/passkeys/1/delete', { form: { reauth_code: '123456' } })).status, 303);
  assert.doesNotMatch(await text('/settings/security'), /ノート PC/);
});

test('端末: 本人確認のうえ、ほかの端末を出せる', async () => {
  assert.equal((await go('/settings/security/sessions/2/revoke', { form: { reauth_code: '1' } })).status, 422);
  assert.equal((await go('/settings/security/sessions/2/revoke', { form: { reauth_code: '123456' } })).status, 303);
  assert.doesNotMatch(await text('/settings/security'), /Safari \/ iPhone/);
});

test('あいことば: 初めては入ったまま設定 → 変えると預かりが閉じる', async () => {
  const set = await text('/settings/password');
  assert.match(set, /name="new_password"/);
  assert.doesNotMatch(set, /name="current_password"/);

  const mismatch = await go('/settings/password', { form: { new_password: 'abcdefgh', confirm_password: 'abcdefgX' } });
  assert.equal(mismatch.status, 422);
  const short = await go('/settings/password', { form: { new_password: 'abc', confirm_password: 'abc' } });
  assert.equal(short.status, 422);

  const first = await go('/settings/password', { form: { new_password: 'abcdefgh', confirm_password: 'abcdefgh' } });
  assert.equal(first.status, 303);
  assert.equal(first.headers.get('location'), '/settings/security');

  const page = await text('/settings/security');
  assert.match(page, /type="password" name="password"/); // これからの本人確認は合言葉
  assert.match(await text('/settings/password'), /name="current_password"/);

  const wrongCurrent = await go('/settings/password', { form: { current_password: 'nope', new_password: 'abcdefgh', confirm_password: 'abcdefgh' } });
  assert.equal(wrongCurrent.status, 422);

  const changed = await go('/settings/password', { form: { current_password: 'secret', new_password: 'newpassw0rd', confirm_password: 'newpassw0rd' } });
  assert.equal(changed.status, 200);
  assert.match(await changed.text(), /href="\/login"/);
  // 預かりは閉じた(札は捨てられた)。
  assert.equal(changed.headers.get('set-cookie')?.includes('sukhi_sid=;'), true);
});

test('引っ越し: 別名を保存し、同意の無い行き先は断られ、整えば移る', async () => {
  sid = ''; // 入りなおし(dev のトークンで、新しい預かり)
  const page = await text('/settings/migration');
  assert.match(page, /value="https:\/\/old\.example\/users\/kuro"/);
  assert.match(page, /action="\/settings\/migration\/move"/);

  const saved = await go('/settings/migration/aliases', { form: { alias: 'https://a.example/users/k' } });
  assert.equal(saved.status, 303);
  const after = await text('/settings/migration');
  assert.match(after, /value="https:\/\/a\.example\/users\/k"/);
  assert.doesNotMatch(after, /old\.example/);

  const removed = await go('/settings/migration/aliases', { form: { alias: 'https://a.example/users/k', remove: '0' } });
  assert.equal(removed.status, 303);
  assert.doesNotMatch(await text('/settings/migration'), /a\.example/);

  const more = await go('/settings/migration/aliases', { form: { alias: '', more: '1' } });
  assert.equal(more.status, 200);

  const noConsent = await go('/settings/migration/move', { form: { target: 'https://new.example/users/k' } });
  assert.equal(noConsent.status, 422);
  assert.match(await noConsent.text(), /class="error"/);
  const bad = await go('/settings/migration/move', { form: { target: 'nope' } });
  assert.equal(bad.status, 422);

  const moved = await go('/settings/migration/move', { form: { target: 'https://back.example/users/k' } });
  assert.equal(moved.status, 303);
  const done = await text('/settings/migration');
  assert.match(done, /href="https:\/\/back\.example\/users\/k"/);
  assert.doesNotMatch(done, /action="\/settings\/migration\/move"/);
});

test('書き出しと読み込み: CSV を書き出し、読み込むと足され、不正な行は飛ばす', async () => {
  sid = '';
  const page = await text('/settings/data');
  assert.match(page, /href="\/settings\/data\/export\/following"/);
  assert.match(page, /action="\/settings\/data\/import\/mutes"/);

  const csv = await go('/settings/data/export/following');
  assert.equal(csv.status, 200);
  assert.match(csv.headers.get('content-type') ?? '', /text\/csv/);
  assert.match(csv.headers.get('content-disposition') ?? '', /following\.csv/);
  assert.match(await csv.text(), /^Account address\r\nbob@remote\.example/);

  const fd = new FormData();
  fd.set('file', new File(['Account address\ncarol@other.example\nghost@nowhere.example\n'], 'in.csv', { type: 'text/csv' }));
  const res = await go('/settings/data/import/following', { method: 'POST', body: fd });
  assert.equal(res.status, 303);
  assert.match(await (await go('/settings/data/export/following')).text(), /carol@other\.example/);

  const empty = new FormData();
  empty.set('file', new File([], ''));
  assert.equal((await go('/settings/data/import/blocks', { method: 'POST', body: empty })).status, 422);

  const big = new FormData();
  big.set('file', new File([new Uint8Array(256 * 1024 + 1)], 'big.csv'));
  assert.equal((await go('/settings/data/import/blocks', { method: 'POST', body: big })).status, 413);

  assert.equal((await go('/settings/data/export/nope')).status, 303);
});
