// SPDX-License-Identifier: AGPL-3.0-or-later
// Clips ── 自分あての会話(自分だけの部屋)を、メモ置き場として使う頁。
//
//   GET  /clips          古い順に並べて、いちばん新しいところ(下)から読む。?q= で探す、?pinned=1 でピンだけ、?max_id= で、もっと古いほう。
//   POST /clips          置く(本文と、ファイルを四つまで。どちらかだけでもいい)。お預かり(四半刻の余白)は、かけない。
//   GET  /clips/talk     呼び鈴のあとの、取りなおし。頁を開いてから届いたぶんだけ(?since=)を返す。
//   GET  /clips/stream   呼び鈴(SSE)。自分あての会話に何か起きたら、中身なしで `poke`。
//
// 部屋は、他の参加者が居ない会話(accounts が空)。まだ一通も無いうちは無い ── 最初の一通が作る(web と同じ)。
// ピンは 📌 のリアクション。押すのは、ふつうのリアクションと同じ道(POST /statuses/:id/react)で、返るのは、この頁のクリップの姿。

import { watchDirect } from '../direct.ts';
import { gwJson, gwPage, GatewayError } from '../gateway.ts';
import { html, type SafeHtml } from '../html.ts';
import { empty, ok, redirect, route, Unauthorized, type Ctx, type Reply } from '../http.ts';
import { bell, later } from '../sse.ts';
import type { Status } from '../types.ts';
import { clipCard, isPinned } from '../views/clips.ts';
import { layout } from '../views/layout.ts';
import { MAX_ATTACHMENTS } from '../views/media.ts';
import { conversations, markedRead, MAX, type Conversation } from './rooms.ts';
import { attachedFiles, failText, needMe, quiet, uploadAttached } from './shared.ts';

const PAGE = 20;
const cursor = (v: string | null): string | null => (v && /^\d{1,20}$/.test(v) ? v : null);
const selfOf = (list: Conversation[] | null): Conversation | undefined => list?.find((c) => c.accounts.length === 0);
const statusesPath = (id: string) => `/api/v1/conversations/${encodeURIComponent(id)}/statuses`;

type View = { q: string; pinned: boolean; maxId: string | null };

function viewOf(ctx: Ctx): View {
  const p = ctx.url.searchParams;
  const q = (p.get('q') ?? '').trim().slice(0, 100);
  // 探しているあいだは、ピンの絞りこみは効かない(web と同じ)。
  return { q, pinned: !q && p.get('pinned') === '1', maxId: cursor(p.get('max_id')) };
}

// もっと古いほうへ。いまの探しかた・絞りかたを引き継ぐ。
const olderHref = (v: View, next: string) =>
  `/clips?max_id=${next}${v.q ? `&q=${encodeURIComponent(v.q)}` : ''}${v.pinned ? '&pinned=1' : ''}`;

async function clipsPage(ctx: Ctx, o: { text?: string; error?: string; status?: number } = {}): Promise<Reply> {
  const t = ctx.t;
  const me = await needMe(ctx);
  const v = viewOf(ctx);
  const list = await conversations(ctx);
  const room = selfOf(list);

  let items: Status[] = []; // 新しい順(gateway のまま)
  let next: string | null = null;
  let failed = list === null;
  if (room) {
    try {
      const page = await gwPage<Status>(ctx, statusesPath(room.id), {
        query: { limit: String(PAGE), ...(v.q ? { q: v.q } : {}), ...(v.maxId ? { max_id: v.maxId } : {}) }
      });
      items = page.items;
      next = page.nextMaxId;
    } catch (e) {
      if (!(e instanceof GatewayError || e instanceof TypeError)) throw e;
      failed = true;
    }
    // 開いたので、読んだ印(自分だけの印)。
    if (room.unread && !v.maxId) await markedRead(ctx, room.id);
  }

  const shown = [...items].reverse().filter((s) => !v.pinned || isPinned(s));
  const newest = items[0]?.id ?? '0';
  const live = !!room && !v.q && !v.maxId && !failed;
  const emptyText =
    shown.length > 0 || failed || v.maxId ? ''
    : v.q ? t('clips.noResults')
    : v.pinned ? t('clips.noPinned')
    : t('clips.empty');

  const body = html`<header class="timeline page-head"><h1>${t('clips.title')}</h1></header>
    <div class="timeline stack clips-page" data-clips${!v.q && !v.maxId ? ' data-clips-bottom' : ''}>
      <div class="clips-tools">
        <form class="hstack hstack-stretch" method="get" action="/clips" role="search">
          <input class="fill" type="search" name="q" value="${v.q}" maxlength="100" placeholder="${t('clips.searchPlaceholder')}" aria-label="${t('clips.searchPlaceholder')}" />
          <button type="submit" class="btn">${t('search.submit')}</button>
        </form>
        ${v.q
          ? html`<a class="chip" href="/clips">${t('clips.showAll')}</a>`
          : html`<a class="chip" href="${v.pinned ? '/clips' : '/clips?pinned=1'}" aria-pressed="${v.pinned ? 'true' : 'false'}">${v.pinned ? t('clips.showAll') : t('clips.pinnedOnly')}</a>`}
      </div>
      ${failed ? html`<p class="error" role="alert">${t('common.readFailed')}</p>` : ''}
      <div id="clips-more">${next
        ? html`<a class="clips-older" href="${olderHref(v, next)}" up-target="#clips-old:before, #clips-more" up-history="false" up-scroll="false" up-revalidate="false">${t('common.loadMore')}</a>`
        : ''}</div>
      <div id="clips-old" class="clips-list">${shown.map((s) => clipCard(ctx, me, s))}</div>
      ${emptyText ? html`<p class="prose-small clips-empty">${emptyText}</p>` : ''}
      ${live
        ? html`<div id="clips-new" class="clips-list" data-room-live="/clips" data-room-query="?since=${newest}${v.pinned ? '&pinned=1' : ''}"></div>`
        : ''}
      <form class="room-write clips-write" method="post" action="/clips" enctype="multipart/form-data"
        x-data="{ names: '', n: 0 }">
        ${o.error ? html`<p class="error" role="alert">${o.error}</p>` : ''}
        <textarea name="body" rows="3" maxlength="${MAX}" placeholder="${t('rooms.placeholder')}" aria-label="${t('rooms.placeholder')}">${o.text ?? ''}</textarea>
        <div class="room-send">
          <label class="chip clips-attach">
            <span>${t('clips.attach')}</span>
            <input type="file" name="files" accept="*/*" multiple class="visually-hidden"
              @change="n = $event.target.files.length; names = [...$event.target.files].map((f) => f.name).join(', ')" />
          </label>
          <span class="muted text-sm clips-names" x-text="names" aria-live="polite"></span>
          <button type="submit" class="btn">${t('rooms.send')}</button>
        </div>
        <p class="muted text-sm" x-show="n > ${MAX_ATTACHMENTS}" x-cloak>${t('clips.maxFiles', { max: MAX_ATTACHMENTS })}</p>
      </form>
    </div>`;
  return ok(layout(ctx, { title: t('clips.title'), me, body }), o.status ?? 200);
}

route('GET', '/clips', (ctx) => clipsPage(ctx));

// 置く。自分あての DM(本文の頭に自分の @)。つづきとして、直前の一通への返信にする(同じ部屋に入る)。
route('POST', '/clips', async (ctx) => {
  const t = ctx.t;
  const me = await needMe(ctx);
  const f = await ctx.form();
  const text = String(f.get('body') ?? '');
  const trimmed = text.trim();
  const files = attachedFiles(f);
  if (!trimmed && files.length === 0) return clipsPage(ctx, { text, error: t('rooms.noWords'), status: 422 });
  if ([...trimmed].length > MAX) return clipsPage(ctx, { text, error: t('rooms.tooLong'), status: 422 });

  try {
    const room = selfOf(await conversations(ctx));
    const mediaIds = await uploadAttached(ctx, files);
    const body: Record<string, unknown> = { status: trimmed ? `@${me.acct} ${trimmed}` : `@${me.acct}`, visibility: 'direct' };
    if (room?.last_status) body.in_reply_to_id = room.last_status.id;
    if (mediaIds.length) body.media_ids = mediaIds;
    await gwJson<Status>(ctx, 'POST', '/api/v1/statuses', { json: body });
  } catch (e) {
    if (e instanceof GatewayError || e instanceof TypeError) {
      // 断られた理由が、こちらに返せるもの(多すぎる・大きすぎる・受けつけない)は、そのまま。ほかは、向こうの不調。
      const asked = e instanceof GatewayError && [413, 422, 429].includes(e.status) ? e.status : 502;
      return clipsPage(ctx, { text, error: failText(ctx, e), status: asked });
    }
    throw e;
  }
  return redirect('/clips');
});

// 呼び鈴のあとの、取りなおし。頁を開いてから(?since= より後に)届いたぶんだけを、古い順に。
// 頁に出ているぶんには、ふれない(読んでいる途中のところを、動かさない)。
route(
  'GET',
  '/clips/talk',
  quiet(async (ctx) => {
    const since = cursor(ctx.url.searchParams.get('since'));
    if (!since) return empty(400);
    const me = await needMe(ctx);
    const room = selfOf(await conversations(ctx));
    if (!room) return ok(html``);
    const items = await gwJson<Status[]>(ctx, 'GET', statusesPath(room.id), { query: { since_id: since, limit: '40' } });
    if (room.unread) await markedRead(ctx, room.id);
    const pinnedOnly = ctx.url.searchParams.get('pinned') === '1';
    const cards: SafeHtml[] = [...items].reverse().filter((s) => !pinnedOnly || isPinned(s)).map((s) => clipCard(ctx, me, s));
    return ok(html`${cards}`);
  })
);

// 呼び鈴(SSE)。部屋の id は、ここで引く(頁は、id を持たない)。部屋が無ければ 404 ── EventSource は繋ぎ直さない。
route('GET', '/clips/stream', async (ctx) => {
  if (!ctx.session?.token) return empty(401);
  let room: Conversation | undefined;
  try {
    await needMe(ctx);
    const list = await conversations(ctx);
    if (list === null) return later();
    room = selfOf(list);
  } catch (e) {
    if (e instanceof Unauthorized) return empty(401);
    return later();
  }
  if (!room) return empty(404);
  const token = ctx.session?.token?.access_token;
  if (!token) return empty(401);
  const id = room.id;
  return bell((ring, gone) => watchDirect(token, id, () => ring('poke'), gone));
});
