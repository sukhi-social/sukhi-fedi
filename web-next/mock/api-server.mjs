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
// DM の WebSocket(/api/v1/streaming?stream=direct)は、web-next の郵便局が Authorization: Bearer 付きで直に開く
// (本物と同じ ── 無ければ 401)。vite の proxy に ws: true が付いていない web(旧)には、届かない。

import { createHash } from 'node:crypto';
import http from 'node:http';
import { fileURLToPath } from 'node:url';

// WebSocket の、サーバから出す一枚(マスクなし)。opcode 1 = text、8 = close。
function textFrame(opcode, payload) {
  const n = payload.length;
  const head = n < 126 ? Buffer.from([0x80 | opcode, n]) : Buffer.from([0x80 | opcode, 126, n >> 8, n & 0xff]);
  return Buffer.concat([head, payload]);
}

export async function startApiServer({ port = Number(process.env.PORT ?? 4000), quiet = false } = {}) {
  // mock.mjs が読まれる前に置く(NOW は読み込み時に決まる)。
  process.env.SUKHI_MOCK_NOW ??= new Date().toISOString();
  const { respond, ME, HOME, PEOPLE, NOTIFICATIONS, MAP, CONVERSATIONS, CLIP_SEED, clipStatus } = await import('./mock.mjs');

  const unknown = new Set();
  const open = new Set();

  // 予約投稿(お預かり)だけは、覚えておく ── 四半刻の見直しの余白を、画面で試すため。
  const scheduled = [];
  let mediaSeq = 0;
  // 新着が「届いた」かどうか(画面で帯を試すため)。POST /__mock/fresh で立つ。
  let freshArrived = false;
  // 翻訳が失敗するか(画面で試すため)。POST /__mock/translate?fail=busy で立つ。
  let translateFail = null;
  // 翻訳の呼びが自動だったか、の記録(テストが見る)。GET /__mock/translate-log。
  const translateAuto = [];
  // フォロー申請への答え(authorize / reject)と、片づけた通知の記録(テストが見る)。GET /__mock/requests-log。
  const requestLog = [];

  // 通知。新しい順・limit・max_id・types[]/exclude_types[] が効く。POST /__mock/notify?type=mention で新着を足し、
  // 開いている流れ(SSE)にも流す(?stream=0 なら流さない ── 切れていたあいだに来た、を試すため)。
  const notifications = NOTIFICATIONS.map((n) => ({ ...n }));
  let notifSeq = 9005;
  // gateway の「ここまで見た」(markers)。まだ置いていなければ null。POST /__mock/marker?to=9003(none で空)で、直に置ける。
  let marker = null;
  // 開いている通知の流れ(GET /api/v1/streaming/user/notification)。
  const bells = new Set();
  // 流れの口が閉じているか(gateway が落ちている・streaming の addon が無い、を試すため)。POST /__mock/stream-end?down=1 で立つ。
  let streamDown = false;
  // 開いている DM の流れ(WebSocket、/api/v1/streaming?stream=direct)。POST /__mock/conversation?id=c1 で、その会話に「何か起きた」を流す。
  const talks = new Set();

  // 路線図(GET /api/map)。POST /__mock/map?down=1 で落ちる(0 で戻る)。local / remote / deliveries / dlq は数を上書き、
  // peers=none で星なし、outbox=none で連合線の数字が取れない状態。reset=1 で元に戻す。呼びは requests-log に残る
  // (「api/map」と、裏の呼びの「api/map bg」)。
  let mapState = {};

  // クリップ(自分あての会話 c0)。書く・ピンを付ける・探す・もっと読む を、行って帰って試すため、覚える(古い順)。
  // POST /__mock/clips?reset=empty で一件も無い人、reset=1 で元の四件、fill=30 で古いのを 30 件足す(もっと読むを試すため)。
  // 呼びは requests-log に残る(「clips list …」「clip {…}」「react PUT 4001 📌」)。
  let clips = CLIP_SEED();
  let clipSeq = 4100;
  let fillSeq = 3999;
  const uploaded = new Map();
  // 書きかけ(Misskey 風の /api/i/notes/drafts)。一アカウントに一つ、空は 204。呼びは requests-log に残る(「draft GET」「draft PUT {…}」「draft DELETE」)。
  // POST /__mock/draft?reset=1 で空に、?text=…&spoiler=…&sensitive=1&visibility=… で置いておく(別の端末で書いた、のつもり)、?fail=1 で GET が 500。
  let noteDraft = null;
  let draftFail = false;
  const plainOf =(h) => String(h).replace(/<[^>]*>/g, '').toLowerCase();
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

  // フォロー招待(/api/v1/follow_invites)と、私的メモ(/api/v1/accounts/:id/note)も覚える ── 作る・取り消す・書くを、行って帰って試すため。
  const invites = [{ code: 'warm-code' }];
  let inviteSeq = 0;
  let tokenSeq = 0;
  const notes = {};

  // プロフィールの編集(PATCH update_credentials)も、覚えておく ── 設定の画面を、行って帰って試すため。
  // 形は gateway の verify_credentials に合わせる(source に原文・ひとこと欄・通知のペース)。
  let me = {
    ...ME,
    location: null,
    birthday: null,
    discoverable: false,
    indexable: false,
    source: { note: 'お茶と、古い本。', fields: [], language: null, notification_hold_minutes: null, notification_grouping: false, home_filter: '', boost_hide_name: false,
      translate_reads: [], translate_learns: [], translate_engine: 'libre', translate_auto: false, translate_deepl_key_hint: null }
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
    if (f.has('home_filter')) {
      const ok = ['hide_boosts', 'hide_sensitive', 'only_media'];
      next.source.home_filter = String(f.get('home_filter')).split(',').filter((x) => ok.includes(x)).sort().join(',');
    }
    if (f.has('boost_hide_name')) next.source.boost_hide_name = bool(f.get('boost_hide_name'));
    // 翻訳。キーは書きこみ専用: 覚えるのは末尾 4 文字の印だけ(本物は暗号化して置く)。
    const langs = (v) => [...new Set(String(v).split(',').map((x) => x.trim().toLowerCase().slice(0, 2)).filter((x) => /^[a-z]{2}$/.test(x)))];
    if (f.has('translate_reads')) next.source.translate_reads = langs(f.get('translate_reads'));
    if (f.has('translate_learns')) next.source.translate_learns = langs(f.get('translate_learns'));
    if (f.has('translate_engine')) next.source.translate_engine = f.get('translate_engine') === 'deepl' ? 'deepl' : 'libre';
    if (f.has('translate_auto')) next.source.translate_auto = bool(f.get('translate_auto'));
    if (f.has('translate_deepl_key')) {
      const key = String(f.get('translate_deepl_key')).trim();
      if (!/^[0-9a-f-]{36}(:fx)?$/i.test(key)) return null;
      next.source.translate_deepl_key_hint = key.replace(/:fx$/, '').slice(-4);
    }
    if (bool(f.get('translate_deepl_key_clear'))) {
      next.source.translate_deepl_key_hint = null;
      if (next.source.translate_engine === 'deepl') next.source.translate_engine = 'libre';
    }
    if (next.source.translate_engine === 'deepl' && !next.source.translate_deepl_key_hint) return null;
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
    closing: null,
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
      if (method === 'GET' && path === '/settings/close/status') return [200, { pending: this.closing }];
      if (path === '/settings/close/request') {
        if (!this.reauthOk(b)) return [403, { error: 'reauth' }];
        this.closing = { scheduled_for: new Date(Date.now() + 86400000).toISOString() };
        return [200, { pending: this.closing }];
      }
      if (path === '/settings/close/cancel') {
        this.closing = null;
        return [200, { pending: null }];
      }
      // 古い投稿のお片づけ。件数は期間で変わる(730 日は 0 件 ── 「することが無い」道も試せる)。実行には本人確認が要る。
      if (path === '/settings/cleanup/preview' || path === '/settings/cleanup/execute') {
        const days = Number(b.older_than_days);
        const affected = ({ 0: 120, 30: 80, 90: 50, 365: 12, 730: 0 })[days];
        if (affected === undefined) return [422, { error: 'invalid_days' }];
        if (path.endsWith('/execute')) {
          if (!this.reauthOk(b)) return [403, { error: 'reauth' }];
          requestLog.push(`cleanup/execute ${days}`);
        }
        return [200, { older_than_days: days, affected, protected: { pinned: 2, direct: 5 } }];
      }
      if (path === '/settings/email/request') {
        if (!/^[^@\s]+@[^@\s]+$/.test(b.email ?? '')) return [422, { error: 'email' }];
        if (b.email === 'taken@example.com') return [422, { error: 'email_taken' }];
        if (b.email === 'limit@example.com') return [429, { error: 'rate_limited' }];
        if (this.email_verified && !this.reauthOk(b)) return [403, { error: 'reauth' }];
        requestLog.push(`email/request ${b.email}`);
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

    // 画像の置き場(POST /api/v1/media)。届いた名前・大きさ・alt を、requestLog に「media 名前 大きさ alt」と残す(テストが見る)。
    if (pathname === '/api/v1/media' && method === 'POST') {
      const f = await new Request('http://localhost/', { method: 'POST', headers: { 'content-type': req.headers['content-type'] ?? '' }, body: Buffer.concat(chunks) }).formData();
      const file = f.get('file');
      const description = String(f.get('description') ?? '');
      const bad = !file || typeof file === 'string' || file.size > 8 * 1024 * 1024;
      const id = `m${++mediaSeq}`;
      if (!bad) requestLog.push(`media ${file.name} ${file.size} ${description}`);
      // 画像でないものは、type が image でなく(gateway と同じ)、名前は filename で返る。
      const made = bad ? null : { id, type: file.type.startsWith('image/') ? 'image' : 'unknown', url: `http://localhost/uploads/${id}`, preview_url: `http://localhost/uploads/${id}`, description: description || null, filename: file.name || null };
      if (made) uploaded.set(id, made);
      res.writeHead(bad ? 422 : 200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(made ?? { error: 'invalid_media' }));
      return;
    }
    // ── クリップ(c0)。自分あての会話は、一件でもあれば、会話の一覧に出る。
    if (pathname === '/api/v1/conversations' && method === 'GET') {
      const self = clips.length ? [{ id: 'c0', unread: false, accounts: [], last_status: clips.at(-1) }] : [];
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify([...CONVERSATIONS, ...self]));
      return;
    }
    if (pathname === '/api/v1/conversations/c0/statuses' && method === 'GET') {
      const q = new URL(req.url ?? '/', 'http://localhost').searchParams;
      const limit = Math.min(Number(q.get('limit')) || 20, 40);
      const needle = (q.get('q') ?? '').trim().toLowerCase();
      const maxId = q.get('max_id');
      const sinceId = q.get('since_id');
      requestLog.push(`clips list q=${needle} max=${maxId ?? ''} since=${sinceId ?? ''} limit=${limit}`);
      let list = [...clips].reverse();
      if (needle) list = list.filter((s) => plainOf(s.content).includes(needle) || s.media_attachments.some((m) => (m.filename ?? '').toLowerCase().includes(needle)));
      if (maxId) list = list.filter((s) => Number(s.id) < Number(maxId));
      if (sinceId) list = list.filter((s) => Number(s.id) > Number(sinceId));
      const page = list.slice(0, limit);
      const headers = { 'content-type': 'application/json' };
      if (list.length > limit) headers.link = `<http://localhost:${port}${pathname}?max_id=${page.at(-1).id}>; rel="next"`;
      res.writeHead(200, headers);
      res.end(JSON.stringify(page));
      return;
    }
    // ピン(📌 のリアクション)。クリップのほかの投稿は、これまでどおり(下の respond に任せる)。
    const rx = pathname.match(/^\/api\/v1\/sukhi\/statuses\/([^/]+)\/react\/([^/]+)$/);
    const clip = rx && clips.find((c) => c.id === rx[1]);
    if (clip && (method === 'PUT' || method === 'DELETE')) {
      const emoji = decodeURIComponent(rx[2]);
      const r = clip.reactions.find((x) => x.name === emoji);
      if (method === 'PUT') {
        if (!r) clip.reactions.push({ name: emoji, count: 1, me: true });
        else if (!r.me) { r.count += 1; r.me = true; }
      } else if (r?.me) {
        r.count -= 1;
        r.me = false;
        if (r.count <= 0) clip.reactions = clip.reactions.filter((x) => x !== r);
      }
      requestLog.push(`react ${method} ${clip.id} ${emoji}`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(clip));
      return;
    }
    // 書く(自分あての DM)。お預かり(scheduled_at)は、下の枝がもう受けている。
    if (pathname === '/api/v1/statuses' && method === 'POST' && !json?.scheduled_at && json?.visibility === 'direct' && /^@kuro(\s|$)/.test(String(json?.status ?? ''))) {
      const text = String(json.status).replace(/^@kuro\s*/, '');
      const made = clipStatus(String(++clipSeq),
        `<p><span class="h-card"><a href="https://sukhi.f3liz.casa/@kuro" class="u-url mention">@<span>kuro</span></a></span> ${esc(text).replace(/\r?\n/g, '<br>')}</p>`, 0, {
          in_reply_to_id: json.in_reply_to_id ?? null,
          media_attachments: (json.media_ids ?? []).map((id) => uploaded.get(id)).filter(Boolean)
        });
      clips.push(made);
      requestLog.push(`clip ${JSON.stringify({ text: json.status, reply: json.in_reply_to_id ?? null, media: json.media_ids ?? [] })}`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(made));
      return;
    }
    if (pathname === '/__mock/clips' && method === 'POST') {
      const q = new URL(req.url ?? '/', 'http://localhost').searchParams;
      if (q.get('reset') === 'empty') clips = [];
      if (q.get('reset') === '1') { clips = CLIP_SEED(); clipSeq = 4100; fillSeq = 3999; }
      for (let i = 0, n = Number(q.get('fill') ?? 0); i < n; i += 1) {
        clips.unshift(clipStatus(String(fillSeq), `<p>@kuro むかしのメモ ${fillSeq}</p>`, 60 * 24 * 10 + (3999 - fillSeq)));
        fillSeq -= 1;
      }
      res.writeHead(204);
      res.end();
      return;
    }
    if (pathname === '/api/i/notes/drafts') {
      res.setHeader('content-type', 'application/json');
      if (method === 'GET') {
        requestLog.push('draft GET');
        if (draftFail) { res.writeHead(500); res.end(JSON.stringify({ error: 'internal_error' })); return; }
        if (!noteDraft) { res.writeHead(204); res.end(); return; }
        res.writeHead(200);
        res.end(JSON.stringify(noteDraft));
        return;
      }
      if (method === 'PUT') {
        requestLog.push(`draft PUT ${JSON.stringify(json)}`);
        // 本物の gateway と同じ: 公開範囲は四つのどれか、折りたたみが切れていれば注意書きは持たない。
        if (!['public', 'unlisted', 'private', 'direct'].includes(json?.visibility ?? 'public')) { res.writeHead(422); res.end(JSON.stringify({ error: 'invalid_draft' })); return; }
        const spoiler = json?.useSpoiler ? String(json.spoiler ?? '') : '';
        noteDraft = { text: String(json?.text ?? ''), spoiler, useSpoiler: spoiler !== '', sensitive: !!json?.sensitive, visibility: json?.visibility ?? 'public', updated_at: new Date().toISOString() };
        res.writeHead(200);
        res.end(JSON.stringify(noteDraft));
        return;
      }
      if (method === 'DELETE') {
        requestLog.push('draft DELETE');
        noteDraft = null;
        res.writeHead(200);
        res.end('{}');
        return;
      }
    }
    if (pathname === '/__mock/draft' && method === 'POST') {
      const q = new URL(req.url ?? '/', 'http://localhost').searchParams;
      if (q.get('reset') === '1') { noteDraft = null; draftFail = false; }
      if (q.get('fail') === '1') draftFail = true;
      if (q.has('text')) {
        const spoiler = q.get('spoiler') ?? '';
        noteDraft = { text: q.get('text'), spoiler, useSpoiler: spoiler !== '', sensitive: q.get('sensitive') === '1', visibility: q.get('visibility') ?? 'public', updated_at: new Date().toISOString() };
      }
      res.writeHead(204);
      res.end();
      return;
    }
    if (pathname === '/api/v1/statuses' && method === 'POST' && json?.scheduled_at) {
      const s = { id: `sch${scheduled.length + 1}`, scheduled_at: json.scheduled_at, params: { text: json.status, media_ids: json.media_ids ?? null, poll: json.poll ?? null, title: json.title ?? null, as_article: json.as_article ?? null, spoiler_text: json.spoiler_text ?? null, visibility: json.visibility ?? null } };
      scheduled.push(s);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(s));
      return;
    }
    // 翻訳(POST /api/v1/statuses/:id/translate)。POST /__mock/translate?fail=busy で、次から失敗を返す(画面で試すため)。
    if (pathname === '/__mock/translate' && method === 'POST') {
      translateFail = new URL(req.url ?? '/', 'http://localhost').searchParams.get('fail') || null;
      res.writeHead(204);
      res.end();
      return;
    }
    // メールの確認の状態を切り替える(メールのお願いを試すため)。POST /__mock/email?verified=0&address=none で「未登録」。
    if (pathname === '/__mock/email' && method === 'POST') {
      const q = new URL(req.url ?? '/', 'http://localhost').searchParams;
      security.email_verified = q.get('verified') !== '0';
      const address = q.get('address');
      if (address) security.email = address === 'none' ? null : address;
      res.writeHead(204);
      res.end();
      return;
    }
    // 人の頁(/@nabi)は、聞かれた acct の人を返す(返事を作る respond() は道しか見ないので、ここで)。
    if (pathname === '/api/v1/accounts/lookup' && method === 'GET') {
      const acct = new URL(req.url ?? '/', 'http://localhost').searchParams.get('acct');
      const who = PEOPLE.find((p) => p.acct === acct || p.username === acct);
      if (who) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify(who));
        return;
      }
    }
    // リストを作る・消す(テストが見る)。作ったら、その一つを返す。
    if (pathname === '/api/v1/lists' && method === 'POST') {
      requestLog.push(`POST lists ${json?.title ?? ''}`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id: '9', title: json?.title ?? '', replies_policy: 'list', exclusive: false }));
      return;
    }
    const la = pathname.match(/^\/api\/v1\/lists\/([^/]+)\/accounts$/);
    if (la && (method === 'POST' || method === 'DELETE')) {
      requestLog.push(`${method} lists/${la[1]}/accounts ${(json?.account_ids ?? []).join(',')}`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{}');
      return;
    }
    const lp = pathname.match(/^\/api\/v1\/lists\/([^/]+)$/);
    if (lp && method === 'PUT') {
      requestLog.push(`PUT lists/${lp[1]} ${JSON.stringify(json)}`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id: lp[1], title: 'お茶の人', ...json }));
      return;
    }
    const ld = pathname.match(/^\/api\/v1\/lists\/([^/]+)$/);
    if (ld && method === 'DELETE') {
      requestLog.push(`DELETE lists/${ld[1]}`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{}');
      return;
    }
    // 入会の申し込み(docs/JOIN.md)。鍵は固定: claim は mock-claim、編集の鍵は mock-key。
    // 'rate@' を含むアドレスは回数超過、'fail@' はメールが出なかった、として答える。
    if (pathname.startsWith('/api/v1/join')) {
      const reply = (status, body) => {
        res.writeHead(status, { 'content-type': 'application/json' });
        res.end(JSON.stringify(body));
      };
      const when = { check_on: '2026-11-12' };
      const words = { receipt: '482913', call_name: 'ゆき', found: '友だちが話していました。', hope: '夜に、ゆっくり読みたいです。', ...when };
      if (pathname === '/api/v1/join/info' && method === 'GET') return reply(200, { greeter: 'くろ', weekday: 4, days_after: 3, ...when });
      if (method === 'POST') {
        const email = String(json?.email ?? '');
        if (pathname === '/api/v1/join' || pathname === '/api/v1/join/email') {
          if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return reply(422, { error: 'validation_failed', details: { email: 'is invalid' } });
          if (email.includes('rate@')) return reply(429, { error: 'rate_limited' });
          if (email.includes('fail@')) return reply(502, { error: 'send_failed' });
        }
        if (pathname === '/api/v1/join') {
          requestLog.push(`join ${email} ${json?.call_name ?? ''}`);
          return reply(202, { receipt: '482913', claim: 'mock-claim', weekday: 4, days_after: 3, ...when });
        }
        if (pathname === '/api/v1/join/received' || pathname === '/api/v1/join/email') {
          if (json?.claim !== 'mock-claim') return reply(404, { error: 'join_not_found' });
          requestLog.push(pathname === '/api/v1/join/email' ? `join/email ${email}` : 'join/received');
          return reply(200, { receipt: '482913' });
        }
        if (pathname === '/api/v1/join/lookup' || pathname === '/api/v1/join/edit') {
          if (json?.key !== 'mock-key') return reply(404, { error: 'join_not_found' });
          if (pathname === '/api/v1/join/edit') requestLog.push(`join/edit ${json?.call_name ?? ''}`);
          return reply(200, words);
        }
      }
    }
    // BOT の鍵(自分の鍵)。鍵は、返事に一度だけ載る。名前が "toomany" なら、回数制限(429)。
    if (pathname === '/api/v1/sukhi/tokens' && method === 'POST') {
      const name = String(json?.name ?? '').trim();
      if (!name) { res.writeHead(422, { 'content-type': 'application/json' }); res.end('{"error":"name_required"}'); return; }
      if (name === 'toomany') { res.writeHead(429, { 'content-type': 'application/json' }); res.end('{"error":"rate_limited"}'); return; }
      requestLog.push(`POST sukhi/tokens ${name} ${json?.expires_in_days}`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ name, token: `mock-key-${name}-${++tokenSeq}`, expires_in_days: json?.expires_in_days }));
      return;
    }
    // 同意の決定(GET/POST /api/v1/sukhi/oauth/authorize)。本物は api が、ブラウザの cookie で決める。
    // ここは cookie と問いの合言葉で出し分ける(test/oauth.test.ts):
    //   session_token が無い          → login(POST は 401)
    //   client_id=ghost / down        → 404 invalid_client / 503
    //   session_tokens も持っている   → pick(choose=2 で、先頭を替えた Set-Cookie つきの続きへ)
    //   redirect_uri が localhost     → redirect(自分の web への戻り。頁なし)
    //   そのほか                      → consent(scope は名前の並び)
    // 呼びは requests-log に残る(「oauth GET …」)。cookie と bearer を何が運んできたか、をテストが見る。
    if (pathname === '/api/v1/sukhi/oauth/authorize') {
      const say = (status, body, headers = {}) => {
        res.writeHead(status, { 'content-type': 'application/json', ...headers });
        res.end(JSON.stringify(body));
      };
      const cookie = String(req.headers.cookie ?? '');
      const ask = method === 'GET' ? Object.fromEntries(new URL(req.url ?? '/', 'http://localhost').searchParams) : (json ?? {});
      requestLog.push(`oauth ${method} client=${ask.client_id ?? ''} choose=${ask.choose ?? ''} cookie=[${cookie}] bearer=${req.headers.authorization ? 'yes' : 'no'}`);
      const signedIn = cookie.split(';').some((c) => c.trim().startsWith('session_token='));
      if (!signedIn) return method === 'POST' ? say(401, { error: 'unauthorized', error_description: 'log in first to authorize this app' }) : say(200, { decision: 'login' });
      if (ask.client_id === 'ghost') return say(404, { error: 'invalid_client', error_description: 'unknown client_id' });
      if (ask.client_id === 'down') return say(503, { error: 'gateway_not_connected' });
      // 読めない戻り先(試験が、わざと変な文字を入れる)でも、mock は落ちない: 自分の host ではないものとして扱う。
      const target = (() => {
        try {
          return new URL(String(ask.redirect_uri));
        } catch {
          return null;
        }
      })();
      const back = (code) => {
        if (!target) return { decision: 'redirect', location: `${ask.redirect_uri}?code=${code}` };
        const to = new URL(target);
        to.searchParams.set('code', code);
        if (ask.state) to.searchParams.set('state', String(ask.state));
        return { decision: 'redirect', location: to.toString() };
      };
      if (method === 'POST') return say(200, back('posted-code'));
      if (cookie.includes('session_tokens=') && !ask.choose) {
        return say(200, { decision: 'pick', accounts: [{ id: 1, username: 'kuro' }, { id: 2, username: 'nabi' }] });
      }
      const swapped = ask.choose ? { 'set-cookie': ['session_token=tok_2; HttpOnly; Path=/', 'sf_signed_in=1; Path=/', 'session_tokens=tok_1; HttpOnly; Path=/'] } : {};
      if (target?.hostname === 'localhost') return say(200, back('first-party-code'), swapped);
      return say(200, { decision: 'consent', app: { name: 'テストの道具', client_id: ask.client_id }, scopes: String(ask.scope ?? 'read').split(/[ +]/).filter(Boolean) }, swapped);
    }
    // フォロー招待。本物は code だけを返す(作るのも、一覧も)。
    if (pathname === '/api/v1/follow_invites' && (method === 'GET' || method === 'POST')) {
      if (method === 'POST') {
        invites.unshift({ code: `new-code-${++inviteSeq}` });
        requestLog.push('POST follow_invites');
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(method === 'POST' ? invites[0] : invites));
      return;
    }
    const fi = pathname.match(/^\/api\/v1\/follow_invites\/([^/]+)$/);
    if (fi && method === 'DELETE') {
      const i = invites.findIndex((x) => x.code === decodeURIComponent(fi[1]));
      if (i >= 0) invites.splice(i, 1);
      requestLog.push(`DELETE follow_invites/${decodeURIComponent(fi[1])}`);
      res.writeHead(i >= 0 ? 200 : 404, { 'content-type': 'application/json' });
      res.end(i >= 0 ? '{}' : '{"error":"invite_not_found"}');
      return;
    }
    // 私的メモ。空で送ると消える。2000 字を超えると、本物と同じく 422。
    const nt = pathname.match(/^\/api\/v1\/accounts\/([^/]+)\/note$/);
    if (nt && method === 'POST') {
      const comment = String(json?.comment ?? '').trim();
      if (comment.length > 2000) {
        res.writeHead(422, { 'content-type': 'application/json' });
        res.end('{"error":"validation_failed"}');
        return;
      }
      if (comment) notes[nt[1]] = comment;
      else delete notes[nt[1]];
      requestLog.push(`note ${nt[1]} ${comment}`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id: nt[1], following: true, followed_by: true, requested: false, ...(comment ? { note: comment } : {}) }));
      return;
    }
    // 関係。頼まれた id だけを返す(本物の gateway と同じ。返す先は r[0] を読むこともある)。メモは、書いたものを足す。
    if (pathname === '/api/v1/accounts/relationships' && method === 'GET') {
      const asked = new URL(req.url ?? '/', 'http://localhost').searchParams.getAll('id[]');
      const rels = JSON.parse(respond(pathname, method).body)
        .filter((r) => asked.length === 0 || asked.includes(r.id))
        .map((r) => (notes[r.id] ? { ...r, note: notes[r.id] } : r));
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(rels));
      return;
    }
    if (pathname === '/__mock/requests-log' && method === 'GET') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(requestLog));
      return;
    }
    if (pathname === '/__mock/map' && method === 'POST') {
      const q = new URL(req.url ?? '/', 'http://localhost').searchParams;
      mapState = q.get('reset') === '1' ? {} : { ...mapState, ...Object.fromEntries(q) };
      res.writeHead(204);
      res.end();
      return;
    }
    if (pathname === '/api/map' && method === 'GET') {
      requestLog.push(req.headers['x-sukhi-purpose'] === 'background' ? 'api/map bg' : 'api/map');
      if (mapState.down === '1') {
        res.writeHead(503, { 'content-type': 'application/json' });
        res.end('{"error":"down"}');
        return;
      }
      const n = (k, d) => (mapState[k] === undefined ? d : Number(mapState[k]));
      const map = {
        ...MAP,
        notes_24h: { local: n('local', MAP.notes_24h.local), remote: n('remote', MAP.notes_24h.remote) },
        deliveries_24h: n('deliveries', MAP.deliveries_24h),
        streams: {
          ...MAP.streams,
          outbox: mapState.outbox === 'none' ? null : MAP.streams.outbox,
          outbox_dlq: { ...MAP.streams.outbox_dlq, held: n('dlq', MAP.streams.outbox_dlq.held) }
        },
        peers: mapState.peers === 'none' ? [] : MAP.peers
      };
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(map));
      return;
    }
    const fr = pathname.match(/^\/api\/v1\/(follow_requests\/[^/]+\/(?:authorize|reject)|notifications\/[^/]+\/dismiss|accounts\/[^/]+\/(?:mute|unmute|block|unblock)|announcements\/[^/]+\/dismiss|feedback|polls\/[^/]+\/votes|conversations\/[^/]+\/read)$/);
    if (fr && method === 'POST') requestLog.push(fr[1]);
    if (pathname === '/__mock/translate-log' && method === 'GET') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(translateAuto));
      return;
    }
    const tr = pathname.match(/^\/api\/v1\/statuses\/([^/]+)\/translate$/);
    if (tr && method === 'POST') {
      // 自動(auto)は、本人がオンにしているときだけ(本物の gateway は auto_off で断る)。
      const body = json ?? {};
      if (body.auto === true && !me.source.translate_auto) {
        res.writeHead(403, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'auto_off' }));
        return;
      }
      translateAuto.push(body.auto === true);
      if (translateFail) {
        const [status, body] = translateFail === 'busy' ? [429, { error: 'busy', retry_after: 10 }] : [422, { error: translateFail }];
        res.writeHead(status, { 'content-type': 'application/json', ...(status === 429 ? { 'retry-after': '10' } : {}) });
        res.end(JSON.stringify(body));
        return;
      }
      const provider = me.source.translate_engine === 'deepl' ? 'DeepL' : 'LibreTranslate';
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        content: tr[1] === '1002' ? '<p>影島でコーヒー。海が見える席に座りました。</p>' : '<p>(mock) 訳です。</p>',
        spoiler_text: '', detected_source_language: 'ko', provider, poll: null, media_attachments: []
      }));
      return;
    }
    if (pathname === '/__mock/fresh' && method === 'POST') {
      freshArrived = true;
      res.writeHead(204);
      res.end();
      return;
    }
    // 通知の一覧。gateway と同じ、新しい順。
    if (pathname === '/api/v1/notifications' && method === 'GET') {
      const q = new URL(req.url ?? '/', 'http://localhost').searchParams;
      const types = q.getAll('types[]');
      const except = q.getAll('exclude_types[]');
      const maxId = /^\d+$/.test(q.get('max_id') ?? '') ? BigInt(q.get('max_id')) : null;
      const items = notifications
        .filter((n) => (types.length === 0 || types.includes(n.type)) && !except.includes(n.type) && (maxId === null || BigInt(n.id) < maxId))
        .sort((a, b) => (BigInt(b.id) > BigInt(a.id) ? 1 : -1))
        .slice(0, Number(q.get('limit') ?? 20));
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(items));
      return;
    }
    // 「ここまで見た」(markers)。置いたら requestLog に「marker 9005」と残す(テストが見る)。
    if (pathname === '/api/v1/markers' && (method === 'GET' || method === 'POST')) {
      if (method === 'POST') {
        marker = String(json?.notifications?.last_read_id ?? marker);
        requestLog.push(`marker ${marker}`);
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(marker === null ? {} : { notifications: { last_read_id: marker, version: 1, updated_at: new Date().toISOString() } }));
      return;
    }
    if (pathname === '/__mock/marker' && method === 'POST') {
      const to = new URL(req.url ?? '/', 'http://localhost').searchParams.get('to');
      marker = to === null || to === 'none' ? null : to;
      res.writeHead(204);
      res.end();
      return;
    }
    // 通知の流れ(SSE)。開いたまま保つ。閉じたら、数から外れる(GET /__mock/streams で数える)。
    if (pathname === '/api/v1/streaming/user/notification' && method === 'GET') {
      if (streamDown) {
        res.writeHead(503, { 'content-type': 'application/json' });
        res.end('{"error":"streaming_unavailable"}');
        return;
      }
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      res.write(':thump\n\n');
      bells.add(res);
      res.on('close', () => bells.delete(res));
      return;
    }
    if (pathname === '/__mock/streams' && method === 'GET') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ open: bells.size, talks: talks.size }));
      return;
    }
    // 開いている流れを、こちらから閉じる(gateway が落ちた・切った、を試すため)。?down=1 なら、新しく開くのも断る(0 で戻す)。
    if (pathname === '/__mock/stream-end' && method === 'POST') {
      const down = new URL(req.url ?? '/', 'http://localhost').searchParams.get('down');
      if (down !== null) streamDown = down === '1';
      for (const b of bells) b.end();
      for (const t of talks) t.end(textFrame(0x8, Buffer.alloc(0)));
      res.writeHead(204);
      res.end();
      return;
    }
    // DM の流れに、その会話の「何か起きた」を流す(Mastodon と同じ形: payload は JSON の文字列)。?raw=… なら、その字をそのまま(形のちがうフレームを試すため)。
    if (pathname === '/__mock/conversation' && method === 'POST') {
      const q = new URL(req.url ?? '/', 'http://localhost').searchParams;
      const text = q.has('raw')
        ? q.get('raw')
        : JSON.stringify({ stream: ['direct'], event: 'conversation', payload: JSON.stringify({ id: q.get('id') ?? 'c1', unread: true, accounts: [], last_status: null }) });
      for (const t of talks) t.write(textFrame(0x1, Buffer.from(text, 'utf8')));
      res.writeHead(204);
      res.end();
      return;
    }
    // 新着を足す。?raw=… なら、足さずに、その字をそのまま流れに流す(形のちがうフレームを試すため)。
    // ?reset=empty なら、通知をぜんぶ空にする(一件も無い人、を試すため)。
    if (pathname === '/__mock/notify' && method === 'POST') {
      const q = new URL(req.url ?? '/', 'http://localhost').searchParams;
      if (q.get('reset') === 'empty') {
        notifications.length = 0;
        res.writeHead(204);
        res.end();
        return;
      }
      if (q.has('raw')) {
        for (const b of bells) b.write(`${q.get('raw')}\n\n`);
        res.writeHead(204);
        res.end();
        return;
      }
      const type = q.get('type') ?? 'mention';
      const base = NOTIFICATIONS.find((n) => n.type === type) ?? NOTIFICATIONS[1];
      const n = { ...base, id: String(++notifSeq), type, created_at: new Date().toISOString() };
      notifications.push(n);
      if (q.get('stream') !== '0') for (const b of bells) b.write(`event: notification\ndata: ${JSON.stringify(n)}\n\n`);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id: n.id }));
      return;
    }
    // タイムラインは 3 件ずつ 2 頁。「もっと読む」と、その先読みを試せる。
    if (/^\/api\/v1\/timelines\/(home|public)$/.test(pathname) && method === 'GET') {
      const params = new URL(req.url ?? '/', 'http://localhost').searchParams;
      // 新着の問い合わせ(since_id)。POST /__mock/fresh で「届いた」ことにするまでは、空。
      if (params.has('since_id')) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify(freshArrived ? HOME.slice(0, 1) : []));
        return;
      }
      const first = !params.get('max_id');
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

  // WebSocket(DM の流れ)の握手。本物と同じに、Authorization: Bearer(か ?access_token=)が無ければ 401。
  // 受けた記録(URL まで)は requestLog に残す ── token が URL に乗っていないことを、テストが見る。
  server.on('upgrade', (req, socket) => {
    const u = new URL(req.url ?? '/', 'http://localhost');
    const refuse = (line) => {
      socket.end(`HTTP/1.1 ${line}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n`);
    };
    if (u.pathname !== '/api/v1/streaming') return refuse('404 Not Found');
    if (!/^Bearer \S+/.test(req.headers.authorization ?? '') && !u.searchParams.get('access_token')) return refuse('401 Unauthorized');
    if (streamDown) return refuse('503 Service Unavailable');
    const key = req.headers['sec-websocket-key'];
    if (typeof key !== 'string') return refuse('400 Bad Request');
    requestLog.push(`ws ${req.url}`);
    const accept = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: ${accept}\r\n\r\n`);
    talks.add(socket);
    // 向こうから来るのは、閉じる合図(opcode 8)くらい。来たら、閉じ返す。
    socket.on('data', (buf) => {
      if ((buf[0] & 0x0f) === 0x8) socket.end(textFrame(0x8, Buffer.alloc(0)));
    });
    socket.on('close', () => talks.delete(socket));
    socket.on('error', () => {});
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
