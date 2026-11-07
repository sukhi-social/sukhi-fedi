// SPDX-License-Identifier: AGPL-3.0-or-later
// ふたりの部屋。DM を、相手ごとの、しずかな一部屋にしたもの。
//
// 中身は、宛先が相手だけの投稿(visibility: direct)── だから、Mastodon や Misskey の人とも、そのまま話せる。
// 別のサーバも、別の仕組みも要らない。ここで作らないもの:
//   ・入力中の表示 / 既読の印 / 未読の数 / 通話(急かすものは、置かない)
//   ・ライブ更新(開いたときと、押しなおしたときに、読み直す)
// 「ひらいていません」は、数ではなく、ことばひとつ。
// 送るときは、ふつうの投稿と同じ「お預かり」(config.postDelayMin)を通る。
// 本文の頭の @相手 は、置く場所を慣習(宛先は本文の先頭の @)に合わせて、見せるときは外す。

import { config } from '../config.ts';
import { html } from '../html.ts';
import { GatewayError, gwJson } from '../gateway.ts';
import { NotFound, ok, redirect, route, type Ctx } from '../http.ts';
import { plainText } from '../maintenance.ts';
import { delayWords, timeWords } from '../time.ts';
import { saveSession } from '../session.ts';
import type { Account, Status } from '../types.ts';
import { layout } from '../views/layout.ts';
import { avatar } from '../views/parts.ts';
import { nameHtml, nameOf } from '../views/account.ts';
import { paragraphs } from './announcements.ts';
import { needMe } from './shared.ts';

type Conversation = { id: string; unread: boolean; accounts: Account[]; last_status: Status | null };
type Scheduled = { id: string; scheduled_at: string };

const idOk = (id: string) => /^[\w-]{1,64}$/.test(id);
const MAX = 5000;

// 本文の頭の「@相手 」を外した、文字だけ。
const spoken = (s: Status) => plainText(s.content ?? '').replace(/^(?:@\S+\s+)+/, '');

function roomName(ctx: Ctx, accounts: Account[]) {
  if (accounts.length === 0) return html`${ctx.t('rooms.self')}`;
  return html`${accounts.map((a, i) => html`${i ? ctx.t('messages.nameSep') : ''}${nameHtml(a)}`)}`;
}

async function conversations(ctx: Ctx): Promise<Conversation[] | null> {
  return gwJson<Conversation[]>(ctx, 'GET', '/api/v1/conversations', { query: { limit: '40' } }).catch(() => null);
}

// ── 一覧 ────────────────────────────────────────────────────
route('GET', '/rooms', async (ctx) => {
  const t = ctx.t;
  const me = await needMe(ctx);
  const list = await conversations(ctx);
  const flash = ctx.takeFlash();
  const now = new Date();
  const body = html`<header class="timeline page-head">
      <h1>${t('rooms.title')}</h1>
      <p class="prose-small"><a class="chip" href="/rooms/new">${t('rooms.newRoom')}</a></p>
    </header>
    <div class="timeline stack">
      ${flash ? html`<p class="${flash.kind === 'error' ? 'error' : 'notice'}" role="status">${flash.text}</p>` : ''}
      <p class="muted text-sm">${t('rooms.lead')}</p>
      ${list === null ? html`<p class="error">${t('common.readFailed')}</p>` : ''}
      ${list && list.length === 0 ? html`<p class="prose-small">${t('rooms.empty')}</p>` : ''}
      ${list && list.length
        ? html`<div>${list.map((c) => {
            const who = c.accounts[0];
            const last = c.last_status;
            return html`<a class="room-row" href="/rooms/${c.id}">
              ${who ? avatar(who.avatar, nameOf(who)) : avatar(me.avatar, nameOf(me))}
              <span class="room-name"><b>${roomName(ctx, c.accounts)}</b>
                <span class="room-last">${last ? (last.account.id === me.id ? t('messages.fromMe') : '') + spoken(last) : ''}</span></span>
              <span class="room-when">${last ? html`<span>${timeWords(last.created_at, ctx.locale, now, ctx.tz)}</span>` : ''}
                ${c.unread ? html`<span class="room-new">${t('rooms.unopened')}</span>` : ''}</span>
            </a>`;
          })}</div>`
        : ''}
    </div>`;
  return ok(layout(ctx, { title: t('rooms.title'), me, body }));
});

// ── 新しい部屋 ──────────────────────────────────────────────
async function newPage(ctx: Ctx, o: { acct?: string; error?: string; status?: number } = {}) {
  const t = ctx.t;
  const me = await needMe(ctx);
  const body = html`<header class="timeline page-head"><h1>${t('rooms.newRoom')}</h1></header>
    <div class="timeline stack">
      <p class="muted text-sm">${t('rooms.newLead')}</p>
      <form class="form" method="post" action="/rooms/new">
        <div class="hstack hstack-stretch">
          <input class="fill" type="text" name="acct" value="${o.acct ?? ''}" required placeholder="${t('listDetail.addPlaceholder')}" aria-label="${t('listDetail.addPlaceholder')}" />
          <button type="submit" class="btn">${t('rooms.start')}</button>
        </div>
      </form>
      ${o.error ? html`<p class="error" role="alert">${o.error}</p>` : ''}
      <p class="muted text-sm">${t('rooms.newNote')}</p>
      <p class="prose-small"><a class="chip" href="/rooms">${t('rooms.back')}</a></p>
    </div>`;
  return ok(layout(ctx, { title: t('rooms.newRoom'), me, body }), o.status ?? 200);
}

route('GET', '/rooms/new', (ctx) => newPage(ctx));

// 相手を引いて、もう部屋があればそこへ。無ければ、書く欄だけの部屋へ。
route('POST', '/rooms/new', async (ctx) => {
  const t = ctx.t;
  const me = await needMe(ctx);
  const typed = String((await ctx.form()).get('acct') ?? '').trim();
  const acct = typed.replace(/^@/, '');
  if (!acct) return newPage(ctx, { acct: typed, status: 422 });
  let who: Account;
  try {
    who = await gwJson<Account>(ctx, 'GET', '/api/v1/accounts/lookup', { query: { acct }, notFound: true });
  } catch (e) {
    if (e instanceof NotFound || e instanceof GatewayError || e instanceof TypeError) {
      return newPage(ctx, { acct: typed, error: t('listDetail.notFoundPerson'), status: 422 });
    }
    throw e;
  }
  if (who.id === me.id) {
    const mine = (await conversations(ctx))?.find((c) => c.accounts.length === 0);
    return redirect(mine ? `/rooms/${mine.id}` : '/rooms/with/me');
  }
  const found = (await conversations(ctx))?.find((c) => c.accounts.some((a) => a.id === who.id));
  return redirect(found ? `/rooms/${found.id}` : `/rooms/with/${encodeURIComponent(who.acct)}`);
});

// ── 部屋 ────────────────────────────────────────────────────
type Room = { id: string | null; people: Account[]; messages: Status[]; unread: boolean };

async function roomPage(ctx: Ctx, room: Room, o: { text?: string; error?: string; status?: number } = {}) {
  const t = ctx.t;
  const me = await needMe(ctx);
  const flash = ctx.takeFlash();
  const who = room.people[0];
  const action = room.id ? `/rooms/${room.id}` : `/rooms/with/${encodeURIComponent(who?.acct ?? 'me')}`;
  const now = new Date();
  const body = html`<header class="room-head">
      <a class="chip" href="/rooms" aria-label="${t('rooms.back')}">‹</a>
      <span class="room-name"><b>${roomName(ctx, room.people)}</b>${who ? html`<span class="muted">@${who.acct}</span>` : ''}</span>
      ${who ? html`<a class="chip" href="/@${who.acct}">${t('rooms.profile')}</a>` : ''}
    </header>
    <div class="timeline stack">
      ${flash ? html`<p class="${flash.kind === 'error' ? 'error' : 'notice'}" role="status">${flash.text}</p>` : ''}
      <p class="muted text-sm">${t('rooms.quiet')}</p>
      ${room.messages.length === 0 ? html`<p class="prose-small">${t('messages.threadEmpty')}</p>` : ''}
      <div class="room-talk">${room.messages.map((s) => {
        const mine = s.account.id === me.id;
        return html`<div class="room-msg ${mine ? 'me' : 'them'}">${paragraphs(spoken(s))}<span class="room-t">${timeWords(s.created_at, ctx.locale, now, ctx.tz)}</span></div>`;
      })}</div>
      <form class="room-write" method="post" action="${action}">
        ${o.error ? html`<p class="error" role="alert">${o.error}</p>` : ''}
        <textarea name="body" rows="4" maxlength="${MAX}" required placeholder="${t('rooms.placeholder')}" aria-label="${t('rooms.placeholder')}">${o.text ?? ''}</textarea>
        <div class="room-send">
          <span class="muted text-sm">${who && who.acct.includes('@') ? t('rooms.remote') : ''}</span>
          <button type="submit" class="btn">${t('rooms.send')}</button>
        </div>
        ${config.postDelayMin > 0 ? html`<p class="muted text-sm">${t('rooms.heldHint', { when: delayWords(config.postDelayMin, ctx.locale) })}</p>` : ''}
      </form>
    </div>`;
  const title = who ? nameOf(who) : t('rooms.self');
  return ok(layout(ctx, { title, me, body }), o.status ?? 200);
}

// いまある部屋を読む。相手は、一覧の行から(無ければ、投稿の書き手のうち、自分でない人)。
async function loadRoom(ctx: Ctx, id: string, markRead: boolean): Promise<Room> {
  const me = await needMe(ctx);
  const [list, newestFirst] = await Promise.all([
    conversations(ctx),
    gwJson<Status[]>(ctx, 'GET', `/api/v1/conversations/${encodeURIComponent(id)}/statuses`, { query: { limit: '40' }, notFound: true })
  ]);
  const entry = list?.find((c) => c.id === id);
  const messages = [...newestFirst].reverse();
  const people =
    entry?.accounts ??
    [...new Map(messages.filter((s) => s.account.id !== me.id).map((s) => [s.account.id, s.account])).values()];
  if (markRead && entry?.unread) {
    // 読んだ、という自分だけの印。相手には届かない。落ちても、部屋は開く。
    await gwJson(ctx, 'POST', `/api/v1/conversations/${encodeURIComponent(id)}/read`, { json: {} }).catch(() => {});
  }
  return { id, people, messages, unread: !!entry?.unread };
}

route('GET', '/rooms/with/:acct', async (ctx) => {
  await needMe(ctx);
  const acct = ctx.params.acct;
  if (acct === 'me') return roomPage(ctx, { id: null, people: [], messages: [], unread: false });
  const who = await gwJson<Account>(ctx, 'GET', '/api/v1/accounts/lookup', { query: { acct }, notFound: true });
  return roomPage(ctx, { id: null, people: [who], messages: [], unread: false });
});

route('GET', '/rooms/:id', async (ctx) => {
  await needMe(ctx);
  if (!idOk(ctx.params.id)) throw new NotFound();
  return roomPage(ctx, await loadRoom(ctx, ctx.params.id, true));
});

// 送る。宛先は本文の頭の @相手、可視性は direct、つづきなら直前の投稿への返信として(同じ部屋に入る)。
async function send(ctx: Ctx, room: Room) {
  const t = ctx.t;
  const text = String((await ctx.form()).get('body') ?? '');
  const trimmed = text.trim();
  const again = (error: string, status: number) => roomPage(ctx, room, { text, error, status });
  if (!trimmed) return again(t('rooms.noWords'), 422);
  if ([...trimmed].length > MAX) return again(t('rooms.tooLong'), 422);

  const mentions = room.people.map((a) => `@${a.acct}`).join(' ');
  const body: Record<string, unknown> = { status: mentions ? `${mentions} ${trimmed}` : trimmed, visibility: 'direct' };
  const last = room.messages[room.messages.length - 1];
  if (last) body.in_reply_to_id = last.id;
  const delayed = config.postDelayMin > 0;
  if (delayed) body.scheduled_at = new Date(Date.now() + config.postDelayMin * 60_000).toISOString();

  try {
    const res = await gwJson<Status | Scheduled>(ctx, 'POST', '/api/v1/statuses', { json: body });
    if (delayed && res && 'scheduled_at' in res) {
      const s = ctx.sess();
      s.pending = [...(s.pending ?? []).filter((p) => Date.parse(p.at) > Date.now()), { id: res.id, text: trimmed, at: res.scheduled_at }];
      saveSession(s);
      ctx.flash('notice', t('rooms.sentHeld', { when: delayWords(config.postDelayMin, ctx.locale) }));
    } else {
      ctx.flash('notice', t('rooms.sent'));
    }
  } catch (e) {
    if (e instanceof GatewayError || e instanceof TypeError) return again(t('rooms.failed'), e instanceof GatewayError && e.status === 429 ? 429 : 502);
    throw e;
  }
  // まだ部屋が無かった(はじめの一通)ときは、お預かりのあいだ、行き先が無い。一覧へ。
  return redirect(room.id ? `/rooms/${room.id}` : '/rooms');
}

route('POST', '/rooms/with/:acct', async (ctx) => {
  await needMe(ctx);
  const acct = ctx.params.acct;
  if (acct === 'me') return send(ctx, { id: null, people: [], messages: [], unread: false });
  const who = await gwJson<Account>(ctx, 'GET', '/api/v1/accounts/lookup', { query: { acct }, notFound: true });
  return send(ctx, { id: null, people: [who], messages: [], unread: false });
});

route('POST', '/rooms/:id', async (ctx) => {
  await needMe(ctx);
  if (!idOk(ctx.params.id)) throw new NotFound();
  return send(ctx, await loadRoom(ctx, ctx.params.id, false));
});
