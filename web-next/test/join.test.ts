// SPDX-License-Identifier: AGPL-3.0-or-later
// 入会の申し込み(docs/JOIN.md): 書く → 関所 → 受付のメール → 「はい」→ 完了 / 「いいえ」→ アドレスの見直し / 編集のリンク。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5198;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4198', PUBLIC_ORIGIN: BASE },
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

let cookie = '';
async function go(path: string, init: RequestInit = {}) {
  const res = await fetch(`${BASE}${path}`, {
    redirect: 'manual',
    ...init,
    headers: { ...(cookie ? { cookie } : {}), origin: BASE, ...init.headers }
  });
  const sets = res.headers.getSetCookie().map((c) => c.split(';')[0]);
  if (sets.length) {
    const jar = new Map(cookie.split('; ').filter(Boolean).map((c) => [c.split('=')[0], c]));
    for (const c of sets) jar.set(c.split('=')[0], c);
    cookie = [...jar.values()].join('; ');
  }
  return res;
}
const post = (path: string, fields: Record<string, string> = {}) => {
  const fd = new FormData();
  for (const [k, v] of Object.entries(fields)) fd.set(k, v);
  return go(path, { method: 'POST', body: fd });
};
const log = async (): Promise<string[]> => (await fetch('http://localhost:4198/__mock/requests-log')).json();

const answers = { call_name: 'ゆき', found: '友だちが話していました。', hope: '夜に、ゆっくり読みたいです。' };

// 書いて送り、関所を通るところまで。
async function apply(email: string) {
  const sent = await post('/join', { ...answers, email });
  assert.equal(sent.status, 303);
  assert.equal(sent.headers.get('location'), '/check?intent=join');
  return go('/check?intent=join');
}

test('申し込みの頁: 三つの質問とメール、確認する日が出る。名前と曜日は gateway のもの', async () => {
  const page = await (await go('/join')).text();
  assert.match(page, /和やかな場所へようこそ/);
  assert.match(page, /くろは、あなたのことが知りたいです/);
  assert.match(page, /name="call_name"/);
  assert.match(page, /name="found"/);
  assert.match(page, /name="hope"/);
  assert.match(page, /name="email"[^>]*required/);
  assert.match(page, /くろが確認するのは、木曜日\(3日後\)です/);
  // 質問は書きたいところだけ ── メール以外は、必須にしない。
  for (const name of ['call_name', 'found', 'hope']) assert.doesNotMatch(page, new RegExp(`name="${name}"[^>]*required`));
});

test('メールが空なら、送らずに戻す(書いたものは残る)', async () => {
  const before = (await log()).length;
  const res = await post('/join', { ...answers, email: '  ' });
  assert.equal(res.status, 422);
  const page = await res.text();
  assert.match(page, /メールアドレスを見直して/);
  assert.ok(page.includes('友だちが話していました。'));
  assert.equal((await log()).length, before);
});

test('関所を通るまで、gateway には何も届かない', async () => {
  const before = (await log()).length;
  const sent = await post('/join', { ...answers, email: 'yuki@example.org' });
  assert.equal(sent.status, 303);
  assert.equal((await log()).length, before);
  const done = await go('/check?intent=join');
  assert.equal(done.status, 303);
  assert.equal(done.headers.get('location'), '/join/asked');
  assert.deepEqual((await log()).slice(before), ['join yuki@example.org ゆき']);
});

test('関所は一度きり(リロードで二度は預けない)', async () => {
  const before = (await log()).length;
  const again = await go('/check?intent=join');
  assert.equal(again.status, 303);
  assert.equal(again.headers.get('location'), '/join');
  assert.equal((await log()).length, before);
});

test('受け取りましたか: 受付番号と、はい・いいえ', async () => {
  const page = await (await go('/join/asked')).text();
  assert.match(page, /受付のメールを送りました/);
  assert.match(page, /482 913/);
  assert.match(page, /action="\/join\/received"/);
  assert.match(page, /href="\/join\/email"/);
});

test('いいえ: アドレスを直して送り直す。だめなアドレスは、理由を言って戻す', async () => {
  const form = await (await go('/join/email')).text();
  assert.match(form, /メールアドレスを見直しましょう/);
  assert.match(form, /value="yuki@example.org"/);

  const bad = await post('/join/email', { email: 'yuki@exmaple' });
  assert.equal(bad.status, 422);
  assert.match(await bad.text(), /メールアドレスを見直してください/);

  const before = (await log()).length;
  const fixed = await post('/join/email', { email: 'yuki@example.com' });
  assert.equal(fixed.status, 303);
  assert.equal(fixed.headers.get('location'), '/join/asked');
  assert.deepEqual((await log()).slice(before), ['join/email yuki@example.com']);
  assert.match(await (await go('/join/asked')).text(), /送り直しました/);
});

test('はい: 完了の頁に、確認する日と、編集はメールのリンクから、と出る', async () => {
  const before = (await log()).length;
  const res = await post('/join/received');
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/join/done');
  assert.deepEqual((await log()).slice(before), ['join/received']);

  const page = await (await go('/join/done')).text();
  assert.match(page, /ありがとうございます/);
  assert.match(page, /くろが確認するのは、木曜日\(3日後\)です/);
  assert.match(page, /メールにあるリンク/);

  // 「はい」のあとは、アドレスを動かす道は閉じる。
  assert.equal((await go('/join/email')).headers.get('location'), '/join/done');
  assert.equal((await go('/join/asked')).headers.get('location'), '/join/done');
});

test('申し込みが無い(別のブラウザ)なら、中の頁は書く頁へ戻す', async () => {
  const saved = cookie;
  cookie = '';
  try {
    for (const path of ['/join/asked', '/join/done', '/join/email']) {
      const res = await go(path);
      assert.equal(res.status, 303, path);
      assert.equal(res.headers.get('location'), '/join', path);
    }
    // 他のブラウザから「はい」とは言えない。
    const before = (await log()).length;
    const res = await post('/join/received');
    assert.equal(res.headers.get('location'), '/join');
    assert.equal((await log()).length, before);
  } finally {
    cookie = saved;
  }
});

test('編集のリンク: 中身が入っていて、アドレスの欄は無い。直すと「直しました」', async () => {
  const page = await (await go('/join/edit/mock-key')).text();
  assert.match(page, /申し込みを編集しています/);
  assert.match(page, /value="ゆき"/);
  assert.match(page, /夜に、ゆっくり読みたいです。/);
  assert.doesNotMatch(page, /name="email"/);

  const before = (await log()).length;
  const res = await post('/join/edit/mock-key', { call_name: 'ゆきの', found: '', hope: '' });
  assert.equal(res.status, 200);
  assert.match(await res.text(), /直しました/);
  assert.deepEqual((await log()).slice(before), ['join/edit ゆきの']);
});

test('編集のリンク: 知らない鍵は、もう使えない、と言う', async () => {
  const res = await go('/join/edit/nope');
  assert.equal(res.status, 404);
  const page = await res.text();
  assert.match(page, /もう使えません/);
  assert.match(page, /href="\/join"/);
  assert.equal((await post('/join/edit/nope', { call_name: 'x' })).status, 404);
});

test('回数が多すぎるとき・メールが出なかったとき: 書いたものを残して、やさしく戻す', async () => {
  cookie = '';
  const limited = await apply('rate@example.org');
  assert.equal(limited.status, 429);
  const page = await limited.text();
  assert.match(page, /続けて送られた/);
  assert.ok(page.includes('友だちが話していました。'));

  const failed = await apply('fail@example.org');
  assert.equal(failed.status, 502);
  assert.match(await failed.text(), /うまく届きませんでした/);
});

test('サインアップの招待コード欄から、申し込みへの道がある(入っていない人が見る頁)', async () => {
  const anon = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: '', QUIET: '1', PORT: '5199', MOCK_PORT: '4199', PUBLIC_ORIGIN: 'http://localhost:5199' },
    stdio: 'ignore'
  });
  try {
    let page = '';
    for (let i = 0; i < 50; i++) {
      try {
        const res = await fetch('http://localhost:5199/signup');
        if (res.status < 500) {
          page = await res.text();
          break;
        }
      } catch {
        // まだ立っていない。
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    assert.match(page, /name="invite_code"/);
    assert.match(page, /href="\/join"/);
  } finally {
    anon.kill();
  }
});

test('英語: 感嘆符なしで、曜日と日数が英語になる', async () => {
  cookie = 'sukhi_locale=en';
  const page = await (await go('/join')).text();
  assert.match(page, /What should we call you\?/);
  assert.match(page, /will look on Thursday \(in 3 days\)/);
  assert.doesNotMatch(page, /Welcome to a gentle place!/);
});
