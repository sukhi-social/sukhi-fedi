// SPDX-License-Identifier: AGPL-3.0-or-later
// リスト: 一覧、作る、消す、リストのタイムライン。gateway に届くことと、頁の形を確かめる。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';

const PORT = 5199;
const BASE = `http://localhost:${PORT}`;
let child: ChildProcess;

before(async () => {
  child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: 'mock', QUIET: '1', PORT: String(PORT), MOCK_PORT: '4199', PUBLIC_ORIGIN: BASE },
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
async function go(path: string, init: RequestInit = {}) {
  const res = await fetch(`${BASE}${path}`, {
    redirect: 'manual',
    ...init,
    headers: { ...(sid ? { cookie: sid } : {}), origin: BASE, ...init.headers }
  });
  const set = res.headers.get('set-cookie')?.split(';')[0];
  if (set) sid = set;
  return res;
}
const log = async (): Promise<string[]> => (await fetch('http://localhost:4199/__mock/requests-log')).json();
const post = (path: string, fields: Record<string, string> = {}) => {
  const fd = new FormData();
  for (const [k, v] of Object.entries(fields)) fd.set(k, v);
  return go(path, { method: 'POST', body: fd });
};

test('一覧: リストが並び、作る欄と、確認つきの「削除」がある', async () => {
  const page = await (await go('/lists')).text();
  assert.match(page, /<form class="form" method="post" action="\/lists">/);
  assert.match(page, /class="list-link" href="\/lists\/1"/);
  assert.match(page, /action="\/lists\/1\/delete" up-confirm=/);
});

test('作る: gateway に届き、できたリストへ', async () => {
  const before = (await log()).length;
  const res = await post('/lists', { title: '  お茶の人たち ' });
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/lists/9');
  assert.deepEqual((await log()).slice(before), ['POST lists お茶の人たち']);
});

test('作る: 名前が空なら、送らずに戻す', async () => {
  const before = (await log()).length;
  const res = await post('/lists', { title: '   ' });
  assert.equal(res.status, 422);
  assert.equal((await log()).length, before);
});

test('消す: gateway に届き、一覧へ戻る', async () => {
  const before = (await log()).length;
  const res = await post('/lists/1/delete');
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/lists');
  assert.deepEqual((await log()).slice(before), ['DELETE lists/1']);
});

test('リストのタイムライン: 名前と、投稿と、一覧へ戻る道', async () => {
  const page = await (await go('/lists/1')).text();
  assert.match(page, /<h1>お茶の人<\/h1>/);
  assert.match(page, /id="li-items"/);
  assert.match(page, /href="\/lists"/);
});

test('入口は、アバターの菜単にある', async () => {
  assert.match(await (await go('/')).text(), /class="nav-menu-item" role="menuitem" href="\/lists"/);
});

test('メンバー: 一覧と、加える欄と、外す口と、ホームへの出し方', async () => {
  const page = await (await go('/lists/1/members')).text();
  assert.match(page, /action="\/lists\/1\/members"/);
  assert.match(page, /id="lm-\d+"/);
  assert.match(page, /action="\/lists\/1\/members\/\d+\/remove"/);
  assert.match(page, /action="\/lists\/1\/gate"/);
  assert.match(page, /name="filter_replies"/);
});

test('加える: 人を引いて、gateway に届く', async () => {
  const before = (await log()).length;
  const res = await post('/lists/1/members', { acct: '@nabi' });
  assert.equal(res.status, 303);
  const got = (await log()).slice(before);
  assert.equal(got.length, 1);
  assert.match(got[0], /^POST lists\/1\/accounts \d+$/);
});

test('外す: gateway に届き、その行が空になる', async () => {
  const before = (await log()).length;
  const res = await go('/lists/1/members/2/remove', { method: 'POST', body: new FormData(), headers: { 'x-up-target': '#lm-2', 'x-up-version': '3.15.0' } });
  assert.equal(res.status, 200);
  assert.match(await res.text(), /<article class="account-row" id="lm-2"><\/article>/);
  assert.deepEqual((await log()).slice(before), ['DELETE lists/1/accounts 2']);
});

test('ホームへの出し方: 外したチェックは「切」として送る', async () => {
  const before = (await log()).length;
  const res = await post('/lists/1/gate', { exclusive: '1', filter_keyword: ' にゃー ', filter_replies: 'to_me' });
  assert.equal(res.status, 303);
  const [line] = (await log()).slice(before);
  const sent = JSON.parse(line.replace(/^PUT lists\/1 /, ''));
  assert.deepEqual(sent, {
    exclusive: true, filter_only_media: false, filter_hide_boosts: false, filter_hide_sensitive: false,
    filter_keyword: 'にゃー', filter_replies: 'to_me'
  });
});

test('プロフィールの「…」から、入れるリストの頁へ。入っているリストには「外す」、そうでなければ「加える」', async () => {
  assert.match(await (await go('/@nabi')).text(), /href="\/accounts\/\d+\/lists"/);
  const page = await (await go('/accounts/2/lists')).text();
  assert.match(page, /id="al-1"[^]*action="\/accounts\/2\/lists\/1\/remove"/);
  assert.match(page, /id="al-2"[^]*action="\/accounts\/2\/lists\/2\/add"/);
});

test('リストへ入れる・外す: gateway に届き、その行だけが返る', async () => {
  const before = (await log()).length;
  const hdr = { 'x-up-target': '#al-2', 'x-up-version': '3.15.0' };
  const add = await go('/accounts/2/lists/2/add', { method: 'POST', body: new FormData(), headers: hdr });
  assert.equal(add.status, 200);
  assert.match(await add.text(), /id="al-2"[^]*\/accounts\/2\/lists\/2\/remove/);
  const rm = await go('/accounts/2/lists/2/remove', { method: 'POST', body: new FormData(), headers: hdr });
  assert.match(await rm.text(), /id="al-2"[^]*\/accounts\/2\/lists\/2\/add/);
  assert.deepEqual((await log()).slice(before), ['POST lists/2/accounts 2', 'DELETE lists/2/accounts 2']);
});
