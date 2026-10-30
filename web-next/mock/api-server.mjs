// SPDX-License-Identifier: AGPL-3.0-or-later
// 偽の API サーバ ── 本物のブラウザから「入った状態」の sukhi を開くための。
//
//   pnpm run mock:api          # localhost:4000 で待つだけ(PORT で変えられる)
//   pnpm run dev:mock          # これと vite dev をいっしょに起こす(dev-mock.mjs)
//
// shots/mock.mjs の返事を、そのまま HTTP で出す。返事を決めるのは mock.mjs の
// respond() の一か所で、Playwright の route(絵を撮る道)も、ここも、それを呼ぶ
// ── 同じデータが、同じ形で出る。違うのは二つだけ:
//
//   ・時計。Playwright は page.clock で止められるが、本物のブラウザは止められない。
//     起動した時刻を基準に「何分前」を並べる(SUKHI_MOCK_NOW)。
//   ・開いたままの口(SSE)。route.fulfill は閉じるしかないが、ここは閉じずに保つ。
//     閉じると、アプリが繋ぎ直しつづける。
//
// vite dev は /api などを localhost:4000 へ流す(vite.config.ts の proxy)ので、
// 画面のコードも、vite.config も、何も変えずに、このサーバが本物のかわりに立つ。
// 本物のバックエンドと同じ :4000 を取るので、どちらかしか同時には立てない。
//
// 知らない口が来たら、空で返しながら一度だけ名前を出す(空っぽの画面に気づけるように)。
// モックの外(.well-known など)は 404。
//
// DM の WebSocket(/api/v1/streaming)は、vite の proxy に ws: true が付いていないので、
// 本物のバックエンドのときも、ここには届かない。アプリは静かに繋ぎ直す。

import http from 'node:http';
import { fileURLToPath } from 'node:url';

export async function startApiServer({ port = Number(process.env.PORT ?? 4000), quiet = false } = {}) {
  // mock.mjs が読まれる前に置く(NOW は読み込み時に決まる)。
  process.env.SUKHI_MOCK_NOW ??= new Date().toISOString();
  const { respond, ME, HOME } = await import('./mock.mjs');

  const unknown = new Set();
  const open = new Set();

  // 予約投稿(お預かり)だけは、覚えておく ── 四半刻の見直しの余白を、画面で試すため。
  const scheduled = [];

  // プロフィールの編集(PATCH update_credentials)も、覚えておく ── 設定の画面を、行って帰って試すため。
  // 形は gateway の verify_credentials に合わせる(source に原文・ひとこと欄・通知のペース)。
  let me = {
    ...ME,
    location: null,
    birthday: null,
    discoverable: false,
    indexable: false,
    source: { note: 'お茶と、古い本。', fields: [], language: null, notification_hold_minutes: null, notification_grouping: false }
  };
  const bool = (v) => v === 'true' || v === true;
  async function patchMe(req, chunks) {
    const type = req.headers['content-type'] ?? '';
    const f = await new Request('http://localhost/', { method: 'POST', headers: { 'content-type': type }, body: Buffer.concat(chunks) }).formData();
    const next = { ...me, source: { ...me.source } };
    if (f.has('display_name')) next.display_name = String(f.get('display_name'));
    if (f.has('note')) {
      next.source.note = String(f.get('note'));
      next.note = `<p>${next.source.note}</p>`;
    }
    for (const k of ['location', 'birthday']) if (f.has(k)) next[k] = String(f.get(k)) || null;
    for (const k of ['locked', 'bot', 'discoverable', 'indexable']) if (f.has(k)) next[k] = bool(f.get(k));
    if (f.has('fields')) {
      next.source.fields = JSON.parse(String(f.get('fields')));
      next.fields = next.source.fields.map((x) => ({ name: x.name, value: x.value, verified_at: null }));
    }
    if (f.has('notification_hold_minutes')) next.source.notification_hold_minutes = Number(f.get('notification_hold_minutes'));
    if (f.has('notification_grouping')) next.source.notification_grouping = bool(f.get('notification_grouping'));
    const big = [...f.values()].find((x) => typeof x !== 'string' && x.size > 8 * 1024 * 1024);
    if (big) return null;
    me = next;
    return me;
  }

  // 書き出し・読み込みの中身。
  const lists = { following: ['bob@remote.example'], blocks: [], mutes: [] };

  // 引っ越し(別名と行き先)。
  const migration = { aliases: ['https://old.example/users/kuro'], moved_to: null };

  // ログインの要素。あいことばは持たない(いまの標準): 本人確認はメールの 6 桁(123456)。
  const security = {
    has_password: false,
    email: 'kuro@example.com',
    email_verified: true,
    pending_email: null,
    totp_enabled: false,
    passkeys: [{ id: 1, nickname: 'ノート PC', created_at: '2026-09-01T00:00:00Z', last_used_at: '2026-10-28T06:00:00Z' }],
    sessions: [
      { id: 1, ip: '203.0.113.x', user_agent: 'Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0', created_at: '2026-10-01T00:00:00Z', last_seen_at: new Date().toISOString(), current: true },
      { id: 2, ip: '198.51.100.x', user_agent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1', created_at: '2026-09-15T00:00:00Z', last_seen_at: '2026-10-20T10:00:00Z', current: false }
    ],
    reauthOk(b) {
      return this.has_password ? b.password === 'secret' : b.reauth_code === '123456';
    },
    state(manageable) {
      return {
        manageable, acct: 'kuro', email: this.email, email_verified: this.email_verified,
        has_password: this.has_password, totp_enabled: this.totp_enabled, totp_pending: false,
        passkeys: this.passkeys
      };
    },
    handle(method, path, b) {
      if (method === 'GET' && path === '/settings/sessions') return [200, { sessions: this.sessions }];
      if (path === '/settings/reauth/request') return [200, { ok: true }];
      if (path === '/settings/email/request') {
        if (!/^[^@\s]+@[^@\s]+$/.test(b.email ?? '')) return [422, { error: 'email' }];
        if (this.email_verified && !this.reauthOk(b)) return [403, { error: 'reauth' }];
        this.pending_email = b.email;
        return [200, { ok: true }];
      }
      if (path === '/settings/email/confirm') {
        if (b.code !== '123456' || !this.pending_email) return [422, { error: 'code' }];
        this.email = this.pending_email; this.email_verified = true; this.pending_email = null;
        return [200, { ok: true, email: this.email }];
      }
      if (path === '/settings/totp/setup') return [200, { secret: 'JBSWY3DPEHPK3PXP', otpauth: 'otpauth://totp/kuro@sukhi.test?secret=JBSWY3DPEHPK3PXP&issuer=sukhi.test' }];
      if (path === '/settings/totp/enable') {
        if (b.code !== '123456') return [422, { error: 'code' }];
        this.totp_enabled = true;
        return [200, { ok: true }];
      }
      if (path === '/settings/totp/disable') {
        if (!this.reauthOk(b)) return [403, { error: 'reauth' }];
        this.totp_enabled = false;
        return [200, { ok: true }];
      }
      if (path === '/settings/passkeys/options') return [200, { ref: 'r1', publicKey: { challenge: 'AAAA', rp: { id: 'localhost', name: 'sukhi' }, user: { id: 'AAAA', name: 'kuro', displayName: 'kuro' }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }], timeout: 60000, attestation: 'none' } }];
      if (path === '/settings/passkeys') {
        this.passkeys.push({ id: this.passkeys.length + 10, nickname: b.nickname || null, created_at: new Date().toISOString(), last_used_at: null });
        return [200, { ok: true }];
      }
      let m = path.match(/^\/settings\/passkeys\/(\d+)\/delete$/);
      if (m) {
        if (!this.reauthOk(b)) return [403, { error: 'reauth' }];
        this.passkeys = this.passkeys.filter((p) => p.id !== Number(m[1]));
        return [200, { ok: true }];
      }
      m = path.match(/^\/settings\/sessions\/(\d+)\/revoke$/);
      if (m) {
        if (!this.reauthOk(b)) return [403, { error: 'reauth' }];
        this.sessions = this.sessions.filter((x) => x.id !== Number(m[1]));
        return [200, { ok: true }];
      }
      if (path === '/settings/password') {
        if (b.new_password !== b.confirm_password) return [422, { error: 'mismatch' }];
        if ((b.new_password ?? '').length < 8) return [422, { error: 'short' }];
        if (!this.has_password) { this.has_password = true; return [200, { ok: true, initial: true }]; }
        if (b.current_password !== 'secret') return [422, { error: 'current' }];
        return [200, { ok: true }];
      }
      if (path === '/settings/password/remove') {
        if (b.password !== 'secret') return [403, { error: 'reauth' }];
        this.has_password = false;
        return [200, { ok: true }];
      }
      return [404, { error: 'not_found' }];
    }
  };

  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const { pathname } = new URL(req.url ?? '/', 'http://localhost');
    const method = req.method ?? 'GET';
    let json = null;
    try { json = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { /* JSON でない */ }

    if (pathname === '/api/v1/statuses' && method === 'POST' && json?.scheduled_at) {
      const s = { id: `sch${scheduled.length + 1}`, scheduled_at: json.scheduled_at, params: { text: json.status } };
      scheduled.push(s);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(s));
      return;
    }
    // タイムラインは 3 件ずつ 2 頁。「もっと読む」と、その先読みを試せる。
    if (/^\/api\/v1\/timelines\/(home|public)$/.test(pathname) && method === 'GET') {
      const first = !new URL(req.url ?? '/', 'http://localhost').searchParams.get('max_id');
      const headers = { 'content-type': 'application/json' };
      if (first) headers.link = `<http://localhost:${port}${pathname}?max_id=page2>; rel="next"`;
      res.writeHead(200, headers);
      res.end(JSON.stringify(first ? HOME.slice(0, 3) : HOME.slice(3)));
      return;
    }
    if (pathname === '/api/v1/scheduled_statuses' && method === 'GET') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(scheduled));
      return;
    }
    const del = pathname.match(/^\/api\/v1\/scheduled_statuses\/([^/]+)$/);
    if (del && method === 'DELETE') {
      const i = scheduled.findIndex((s) => s.id === del[1]);
      if (i >= 0) scheduled.splice(i, 1);
      res.writeHead(i >= 0 ? 200 : 404, { 'content-type': 'application/json' });
      res.end('{}');
      return;
    }

    if (pathname === '/api/v1/accounts/verify_credentials' && method === 'GET') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(me));
      return;
    }
    if (pathname === '/api/v1/accounts/update_credentials' && method === 'PATCH') {
      const updated = await patchMe(req, chunks).catch(() => null);
      res.writeHead(updated ? 200 : 422, { 'content-type': 'application/json' });
      res.end(JSON.stringify(updated ?? { error: 'validation_failed', details: {} }));
      return;
    }

    // ログインの要素・端末・引っ越し(設定の「ログインと安全」「引っ越し」)── 覚えて、行って帰って試せる。
    // cookie 専用の口は `session_token=mock` が要る(本物と同じ。無ければ manageable: false / 401)。
    const reply = (status, body) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    if (pathname === '/auth/state' || pathname.startsWith('/settings/')) {
      const signedIn = /(?:^|;\s*)session_token=mock\b/.test(req.headers.cookie ?? '');
      if (pathname === '/auth/state' && method === 'GET') return reply(200, security.state(signedIn));
      if (!signedIn) return reply(401, { error: 'unauthorized' });
      const [status, body] = security.handle(method, pathname, json ?? {});
      return reply(status, body);
    }
    // 書き出し・読み込み(フォロー・ブロック・ミュート)。読み込みは行を数えるだけ(一行ごとに足す)。
    const porter = pathname.match(/^\/api\/v1\/accounts\/(export|import)\/(following|blocks|mutes)$/);
    if (porter) {
      const [, op, kind] = porter;
      if (op === 'export' && method === 'GET') {
        res.writeHead(200, { 'content-type': 'text/csv; charset=utf-8' });
        res.end(`Account address\r\n${lists[kind].join('\r\n')}\r\n`);
        return;
      }
      if (op === 'import' && method === 'POST') {
        const rows = String(json?.data ?? '').split(/\r?\n/).map((l) => l.split(',')[0].trim().replace(/^@/, '')).filter((l) => l && l !== 'Account address');
        if (rows.length > 1000) return reply(422, { error: 'too_many_rows' });
        const good = rows.filter((r) => /^[\w.-]+(@[\w.-]+)?$/.test(r) && !r.startsWith('ghost'));
        for (const r of good) if (!lists[kind].includes(r)) lists[kind].push(r);
        // 本物のフォローは、受け付けて(queued)順に出す。ブロック・ミュートは、その場で。
        if (kind === 'following') return reply(200, { imported: 0, skipped: 0, unresolved: [], queued: rows.length });
        return reply(200, { imported: good.length, skipped: rows.length - good.length, unresolved: rows.filter((r) => !good.includes(r)) });
      }
    }
    if (pathname === '/api/v1/accounts/migration' && method === 'GET') return reply(200, migration);
    if (pathname === '/api/v1/accounts/migration/aliases' && method === 'POST') {
      const list = json?.aliases ?? [];
      if (list.length > 5) return reply(422, { error: 'too_many_aliases' });
      migration.aliases = list;
      return reply(200, { aliases: list });
    }
    if (pathname === '/api/v1/accounts/migration/move' && method === 'POST') {
      const target = String(json?.target ?? '');
      if (migration.moved_to) return reply(422, { error: 'already_moved' });
      if (!/^https?:\/\//.test(target)) return reply(422, { error: 'invalid_target' });
      if (!target.includes('back')) return reply(422, { error: 'target_must_alias_back' });
      migration.moved_to = target;
      return reply(200, { moved_to: target });
    }

    const out = respond(pathname, method);

    if (!out) {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end('{"error":"not a mocked path"}');
      return;
    }

    if (out.unknown) {
      const key = `${method} ${pathname}`;
      if (!quiet && !unknown.has(key)) console.log(`[mock-api] 返事を用意していない口(空で返した): ${key}`);
      unknown.add(key);
    }

    const headers = { 'cache-control': 'no-store' };
    if (out.contentType) headers['content-type'] = out.contentType;
    res.writeHead(out.status, headers);

    if (out.keepOpen) {
      // 開いたまま保つ。ブラウザが切ったら、こちらも閉じる。
      res.write(out.body);
      open.add(res);
      res.on('close', () => open.delete(res));
      return;
    }
    res.end(out.body);
  });

  await new Promise((resolve, reject) => {
    server.once('error', (err) => {
      if (err.code === 'EADDRINUSE') {
        reject(new Error(`:${port} はもう使われています(本物のバックエンドが立っていませんか)。PORT=… で変えられますが、vite.config.ts の proxy は :4000 を見ます。`));
      } else {
        reject(err);
      }
    });
    // vite の proxy が引く "localhost" と同じ名前で待つ(::1 と 127.0.0.1 の食い違いを避ける)。
    server.listen(port, 'localhost', resolve);
  });

  return {
    port,
    close() {
      for (const res of open) res.end();
      return new Promise((resolve) => server.close(resolve));
    }
  };
}

// `node shots/api-server.mjs` で直接動かしたときだけ、待ち受ける。
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const api = await startApiServer();
    console.log(`[mock-api] http://localhost:${api.port} で待っています(shots/mock.mjs の返事)。止めるのは Ctrl-C。`);
    const stop = () => api.close().then(() => process.exit(0));
    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);
  } catch (err) {
    console.error(`[mock-api] ${err.message}`);
    process.exit(1);
  }
}
