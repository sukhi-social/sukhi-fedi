// SPDX-License-Identifier: AGPL-3.0-or-later
// 利用者の IP(CF-Connecting-IP)を、gateway に伝える。伝えないと、gateway の回数制限
// (メールを送る口は 1 時間に 12 回/IP、など)が、web-next のコンテナ一つの IP で数えられて、
// 利用者みんなで一つの上限を分け合う。偽の gateway で、実際に届くヘッダーを見る。
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type IncomingHttpHeaders, type Server } from 'node:http';
import { spawn, type ChildProcess } from 'node:child_process';
import { clientHeaders } from '../server/gateway.ts';

const seen: { path: string; headers: IncomingHttpHeaders }[] = [];
let gateway: Server;
let child: ChildProcess;
const WEB = 5194;
const GW = 4194;
const BASE = `http://localhost:${WEB}`;

before(async () => {
  gateway = createServer((req, res) => {
    seen.push({ path: req.url ?? '', headers: req.headers });
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
  });
  await new Promise<void>((r) => gateway.listen(GW, r));

  child = spawn('node', ['server/main.ts'], {
    env: { ...process.env, QUIET: '1', PORT: String(WEB), GATEWAY_URL: `http://localhost:${GW}`, PUBLIC_ORIGIN: BASE },
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

after(() => {
  child?.kill();
  gateway?.close();
});

async function sendLoginCode(ip?: string) {
  seen.length = 0;
  const extra: Record<string, string> = ip ? { 'cf-connecting-ip': ip } : {};
  const first = await fetch(`${BASE}/login`, {
    method: 'POST',
    redirect: 'manual',
    headers: { 'content-type': 'application/x-www-form-urlencoded', origin: BASE, ...extra },
    body: new URLSearchParams({ method: 'email', step: 'request', email: 'a@b.c' })
  });
  const sid = first.headers.get('set-cookie')?.split(';')[0] ?? '';
  // anubis を通ったあとの GET /check が、コードを送る。
  await fetch(`${BASE}/check?intent=login-email`, { redirect: 'manual', headers: { cookie: sid, ...extra } });
  return seen.find((s) => s.path === '/login/email/request');
}

test('メールのコードを送る要求に、利用者の CF-Connecting-IP がついて gateway に届く', async () => {
  const sent = await sendLoginCode('203.0.113.9');
  assert.ok(sent, 'gateway に /login/email/request が届いた');
  assert.equal(sent.headers['cf-connecting-ip'], '203.0.113.9');
});

test('ヘッダーが無い要求には、何も足さない(dev・mock)', async () => {
  const sent = await sendLoginCode();
  assert.ok(sent);
  assert.equal(sent.headers['cf-connecting-ip'], undefined);
});

test('clientHeaders: 最初の一つを取り、空は無いものとして扱う', () => {
  const ctx = (v: string | string[] | undefined) => ({ req: { headers: { 'cf-connecting-ip': v } } }) as never;
  assert.deepEqual(clientHeaders(ctx('198.51.100.7')), { 'cf-connecting-ip': '198.51.100.7' });
  assert.deepEqual(clientHeaders(ctx(['198.51.100.7', 'x'])), { 'cf-connecting-ip': '198.51.100.7' });
  assert.deepEqual(clientHeaders(ctx(' ')), {});
  assert.deepEqual(clientHeaders(ctx(undefined)), {});
});
