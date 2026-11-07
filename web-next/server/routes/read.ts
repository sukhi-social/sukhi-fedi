// SPDX-License-Identifier: AGPL-3.0-or-later
// 読む頁: タイムライン、タグ、投稿の詳細、プロフィール、さがす。
//
// どれも、サーバで一枚の手紙(HTML)に組み立てて返す。「もっと読む」だけ、Unpoly が
// 続きを今の列のうしろに足す(#…-items:after)。無限スクロールはしない ── 列には、かならず終わりが来る。

import { html, raw } from '../html.ts';
import { gwJson, gwPage, GatewayError } from '../gateway.ts';
import { ok, route, NotFound, type Ctx, type Reply } from '../http.ts';
import type { Account, Context, Relationship, SearchResult, Status, TimelineKind } from '../types.ts';
import { renderEmojis } from '../emoji.ts';
import { timeWords } from '../time.ts';
import { layout } from '../views/layout.ts';
import { avatar, icon } from '../views/parts.ts';
import { statusCard } from '../views/status.ts';
import { accountRow, nameHtml, nameOf, profileActions } from '../views/account.ts';
import { spreadWithinMoments } from '../shuffle.ts';
import { maybeMe, replyAcctsFor, statusList } from './shared.ts';

const KINDS: TimelineKind[] = ['home', 'public', 'bubble', 'tag'];

// 絞りこみの種類。順番は、画面に出す順。ホームの「デフォルト」は、この名前のカンマ区切りで
// gateway(accounts.home_filter)に置く ── 知らない名前は、ここでも読み捨てる。
export const FILTERS = ['only_media', 'hide_boosts', 'hide_sensitive'] as const;
export type FilterName = (typeof FILTERS)[number];

export function savedFilters(me: Account | null): Set<FilterName> {
  const have = (me?.source?.home_filter ?? '').split(',');
  return new Set(FILTERS.filter((f) => have.includes(f)));
}

// 今の絞りこみ。`filtered=1` が付いているときは、フォームから来た値がすべて(外した、も含めて)。
// 付いていないとき(タブ・ナビから来たとき)、ホームだけは、その人のデフォルトから始める。
export function activeFilters(me: Account | null, kind: TimelineKind, q: URLSearchParams): Set<FilterName> {
  const picked =
    q.get('filtered') === '1' || kind !== 'home'
      ? new Set(FILTERS.filter((f) => q.get(f) === '1'))
      : savedFilters(me);
  // hide_boosts が効くのはホームだけ(public / tag にはブーストが混ざらない)。
  if (kind !== 'home') picked.delete('hide_boosts');
  return picked;
}

// 「新着があるか」の問い合わせと、頁の組み立てが、同じクエリを使うように一か所に。
export function timelineRequest(kind: TimelineKind, tag: string, on: Set<FilterName>): { path: string; query: Record<string, string | undefined> } {
  const query: Record<string, string | undefined> = {
    only_media: on.has('only_media') ? '1' : undefined,
    hide_boosts: on.has('hide_boosts') ? '1' : undefined,
    hide_sensitive: on.has('hide_sensitive') ? '1' : undefined
  };
  if (kind === 'home') return { path: '/api/v1/timelines/home', query };
  if (kind === 'tag') return { path: `/api/v1/timelines/tag/${encodeURIComponent(tag)}`, query };
  query[kind === 'bubble' ? 'bubble' : 'local'] = '1';
  return { path: '/api/v1/timelines/public', query };
}

function keepForFresh(kind: TimelineKind, tag: string, on: Set<FilterName>): [string, string][] {
  const out: [string, string][] = [['kind', kind]];
  if (kind === 'tag') out.push(['tag', tag]);
  out.push(['filtered', '1']);
  for (const f of on) out.push([f, '1']);
  return out;
}

// ── タイムライン ────────────────────────────────────────────────
export async function timeline(ctx: Ctx, tagParam: string | null) {
  const t = ctx.t;
  const me = await maybeMe(ctx);
  const q = ctx.url.searchParams;

  let kind = (tagParam ? 'tag' : q.get('kind')) as TimelineKind | null;
  if (!kind || !KINDS.includes(kind)) kind = me ? 'home' : 'public';
  if (kind === 'home' && !me) kind = 'public';
  const tag = (tagParam ?? q.get('tag') ?? '').trim().replace(/^#/, '');
  const maxId = q.get('max_id') ?? undefined;
  const on = activeFilters(me, kind, q);
  const req = timelineRequest(kind, tag, on);
  const path = req.path;
  const query: Record<string, string | undefined> = { limit: '20', max_id: maxId, ...req.query };

  let items: Status[] = [];
  let nextMaxId: string | null = null;
  // gateway は新しい順で返す。並べなおす前の先頭が、いちばん新しい投稿(新着の目印)。
  let newestId: string | undefined;
  let problem: string | null = null;
  if (kind === 'tag' && !tag) {
    // タグがまだ決まっていない。取りに行かない。
  } else {
    try {
      const page = await gwPage<Status>(ctx, path, { query, auth: kind === 'home' ? true : 'optional' });
      // 時間のことばが同じ投稿は、順序が言えない。その中で、同じ人が続かないように並べなおす。
      newestId = page.items[0]?.id;
      items = spreadWithinMoments(page.items, ctx.locale, ctx.session?.id ?? 'anon', new Date(), ctx.tz);
      nextMaxId = page.nextMaxId;
    } catch (e) {
      if (e instanceof GatewayError || e instanceof TypeError) {
        problem = e instanceof TypeError ? t('common.reconnecting') : t('common.deliverFailedRetry');
      } else throw e;
    }
  }

  const keep = new URLSearchParams();
  keep.set('kind', kind);
  if (kind === 'tag') keep.set('tag', tag);
  keep.set('filtered', '1');
  for (const f of on) keep.set(f, '1');
  const moreHref = nextMaxId ? `/timeline?${keep}&max_id=${encodeURIComponent(nextMaxId)}` : null;

  const tab = (k: TimelineKind, label: string) =>
    html`<a class="tab" href="/timeline?kind=${k}${k === 'tag' && tag ? `&tag=${encodeURIComponent(tag)}` : ''}" aria-current="${kind === k ? 'true' : null}">${label}</a>`;

  const empty =
    kind === 'home' ? t('timeline.emptyHome')
    : kind === 'bubble' ? t('timeline.emptyBubble')
    : kind === 'tag' && !tag ? t('timeline.emptyTagPrompt')
    : kind === 'tag' ? t('timeline.emptyTag', { tag })
    : t('timeline.emptyGeneric');

  const filterLabel: Record<FilterName, string> = {
    only_media: t('timeline.onlyMedia'),
    hide_boosts: t('timeline.hideBoosts'),
    hide_sensitive: t('timeline.hideSensitive')
  };
  const shown = FILTERS.filter((f) => f !== 'hide_boosts' || kind === 'home');
  const check = (name: FilterName) =>
    html`<label class="filter-check"><input type="checkbox" name="${name}" value="1" ${on.has(name) ? raw('checked') : ''} /> <span>${filterLabel[name]}</span></label>`;

  // デフォルトを置けるのは、ホームだけ(入っている人の、自分の設定なので)。
  const canDefault = kind === 'home' && !!me;
  const saved = savedFilters(me);
  const sameAsSaved = saved.size === on.size && [...on].every((f) => saved.has(f));
  const savedWords = saved.size ? FILTERS.filter((f) => saved.has(f)).map((f) => filterLabel[f]).join('、') : t('timeline.defaultNone');

  // 新着の帯。ふだんは隠れていて、新しい投稿が届いたとき(public/js/fresh.js が確かめて)そっと現れる。
  // 押すまで、列は動かない。先頭の id は、「ここより新しいもの」を訊くための目印。
  const newest = !maxId ? newestId : undefined;
  const freshBar =
    newest && !problem
      ? html`<div class="fresh" hidden data-fresh="/timeline/fresh?${new URLSearchParams([...keepForFresh(kind, tag, on), ['since', newest]])}">
          <button type="button" class="fresh-btn" up-follow="false" title="${t('timeline.freshHint')}">
            <span class="fresh-text">${t('timeline.fresh')}</span>
          </button>
        </div>`
      : '';

  const body = html`<h1 class="visually-hidden">${kind === 'tag' && tag ? `#${tag}` : t(kind === 'home' ? 'timeline.tabHome' : kind === 'bubble' ? 'timeline.tabBubble' : 'timeline.tabPublic')}</h1>
    <nav class="tabs timeline" aria-label="${t('timeline.tabsLabel')}">
      ${me ? tab('home', t('timeline.tabHome')) : ''}${tab('public', t('timeline.tabPublic'))}${tab('bubble', t('timeline.tabBubble'))}${tab('tag', t('timeline.tabTag'))}
      <details class="timeline-filter">
        <summary class="chip" ${on.size ? raw('data-on="true"') : ''}>${icon('settings')}<span class="filter-label">${t('timeline.filter')}</span>${on.size ? html`<span class="visually-hidden"> (${t('timeline.filterOn')})</span>` : ''}</summary>
        <form method="get" action="/timeline" class="filter-form">
          <input type="hidden" name="kind" value="${kind}" /><input type="hidden" name="filtered" value="1" />${kind === 'tag' ? html`<input type="hidden" name="tag" value="${tag}" />` : ''}
          ${shown.map((f) => check(f))}
          <div class="filter-actions">
            <button type="submit" class="chip">${t('timeline.apply')}</button>
            ${canDefault
              ? html`<button type="submit" class="chip" formmethod="post" formaction="/timeline/default" up-target="main">${t('timeline.makeDefault')}</button>`
              : ''}
          </div>
          ${canDefault
            ? html`<p class="muted text-sm filter-default">${sameAsSaved && saved.size ? t('timeline.isDefault') : t('timeline.defaultNow', { what: savedWords })}</p>
                ${saved.size ? html`<button type="submit" class="filter-clear" name="reset" value="1" formmethod="post" formaction="/timeline/default" up-target="main">${t('timeline.clearDefault')}</button>` : ''}`
            : ''}
        </form>
      </details>
    </nav>
    ${kind === 'tag'
      ? html`<form class="timeline form" method="get" action="/timeline" style="margin-bottom: var(--space-4);">
          <input type="hidden" name="kind" value="tag" />
          <label class="stack-tight"><span>${t('timeline.tagLabel')}</span>
            <input type="text" name="tag" value="${tag}" placeholder="${t('timeline.tagPlaceholder')}" />
          </label>
        </form>`
      : ''}
    <section class="timeline">
      ${freshBar}
      ${problem ? html`<p class="error">${problem}</p>` : ''}
      ${items.length === 0 && !problem ? html`<p class="prose-small">${empty}</p>` : ''}
      ${await statusList(ctx, items, { me, idPrefix: 'tl', moreHref })}
    </section>`;

  // 「もっと読む」で続きの断片だけを要求されたときは、外側の枠(レイアウト)を省いて返す。
  if (ctx.isUp && ctx.upTarget && ctx.upTarget.includes('tl-items:after')) {
    return ok(await statusList(ctx, items, { me, idPrefix: 'tl', moreHref }));
  }

  return ok(layout(ctx, { title: t('nav.home'), me, entrance: !me, legal: !me, body }));
}

// 「新しい投稿はありますか」── いちばん上の id より新しいものが、一件でもあるかだけを返す。
// 数は返さない(数を出さない作法)。中身も返さない。押されたら、ふつうに頁を取りなおす。
// 取れなかったとき(通信の不調・gateway の不調)は、「無い」と同じ ── 帯は出ないだけで、何も壊れない。
route('GET', '/timeline/fresh', async (ctx) => {
  const q = ctx.url.searchParams;
  const me = await maybeMe(ctx);
  let kind = q.get('kind') as TimelineKind | null;
  if (!kind || !KINDS.includes(kind)) kind = me ? 'home' : 'public';
  if (kind === 'home' && !me) kind = 'public';
  const tag = (q.get('tag') ?? '').trim().replace(/^#/, '');
  const since = q.get('since') ?? '';
  const none = (): Reply => ({ status: 204, headers: { 'cache-control': 'no-store' }, body: '' });
  if (!/^\d+$/.test(since) || (kind === 'tag' && !tag)) return none();
  const on = activeFilters(me, kind, new URLSearchParams([...q, ['filtered', '1']]));
  const req = timelineRequest(kind, tag, on);
  try {
    const page = await gwPage<Status>(ctx, req.path, { query: { ...req.query, since_id: since, limit: '1' }, auth: kind === 'home' ? true : 'optional' });
    if (page.items.length === 0) return none();
    return { status: 200, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }, body: '{"fresh":true}' };
  } catch {
    return none();
  }
});

route('GET', '/timeline', (ctx) => timeline(ctx, null));
route('GET', '/tags/:tag', (ctx) => timeline(ctx, ctx.params.tag));

// ── フォロワー・フォロー中の一覧 ─────────────────────────────────
// 数は出さない(プロフィールと同じ)。名前の並びだけを、ここに置く。
// '/@:acct/:id' より先に置く ── そうしないと "followers" という名前の投稿として探されてしまう。
async function connections(ctx: Ctx, kind: 'followers' | 'following') {
  const t = ctx.t;
  const me = await maybeMe(ctx);
  const acct = ctx.params.acct;

  let account: Account;
  try {
    account = await gwJson<Account>(ctx, 'GET', '/api/v1/accounts/lookup', { auth: false, query: { acct }, notFound: true });
  } catch (e) {
    if (e instanceof NotFound) {
      return ok(
        layout(ctx, { title: acct, me, entrance: !me, body: html`<p class="error">${t('common.acctNotFound', { acct })}</p><p><a class="chip" href="/timeline">${t('common.backToTimeline')}</a></p>` }),
        404
      );
    }
    throw e;
  }

  const items = await gwJson<Account[]>(ctx, 'GET', `/api/v1/accounts/${encodeURIComponent(account.id)}/${kind}`, { auth: 'optional' }).catch(() => null);
  let rels = new Map<string, Relationship>();
  if (me && items?.length) {
    const rs = await gwJson<Relationship[]>(ctx, 'GET', '/api/v1/accounts/relationships', { query: { 'id[]': items.map((a) => a.id) } }).catch(() => []);
    rels = new Map(rs.map((r) => [r.id, r]));
  }

  const title = kind === 'followers' ? t('profile.followersSuffix') : t('profile.followingSuffix');
  const body = html`<header class="timeline page-head">
      <h1>${title}</h1>
      <p class="muted"><a href="/@${account.acct}">${nameHtml(account)}</a> <span>@${account.acct}</span></p>
    </header>
    ${items === null ? html`<p class="error">${t('profile.listError')}</p>` : ''}
    ${items && items.length === 0 ? html`<p class="prose-small">${t(kind === 'followers' ? 'profile.noFollowers' : 'profile.noFollowing')}</p>` : ''}
    ${items && items.length ? html`<section class="account-list">${items.map((a) => accountRow(ctx, a, rels.get(a.id) ?? null, me))}</section>` : ''}`;
  return ok(layout(ctx, { title: `${nameOf(account)} · ${title}`, me, entrance: !me, legal: !me, body }));
}

route('GET', '/@:acct/followers', (ctx) => connections(ctx, 'followers'));
route('GET', '/@:acct/following', (ctx) => connections(ctx, 'following'));

// ── 投稿の詳細 ──────────────────────────────────────────────────
route('GET', '/@:acct/:id', async (ctx) => {
  const me = await maybeMe(ctx);
  const auth = 'optional' as const;
  const id = encodeURIComponent(ctx.params.id);
  const [status, thread] = await Promise.all([
    gwJson<Status>(ctx, 'GET', `/api/v1/statuses/${id}`, { auth, notFound: true }),
    gwJson<Context>(ctx, 'GET', `/api/v1/statuses/${id}/context`, { auth }).catch(() => ({ ancestors: [], descendants: [] }) as Context)
  ]);
  const all = [...thread.ancestors, status, ...thread.descendants];
  const replyAccts = await replyAcctsFor(ctx, all);
  const card = (s: Status, full = false) => statusCard(ctx, s, { me, replyAccts, full });

  const body = html`<section class="timeline">
    ${thread.ancestors.map((s) => card(s))}
    ${card(status, true)}
    ${thread.descendants.map((s) => card(s))}
    <p class="prose-small" style="margin-top: var(--space-6);"><a href="/timeline">${ctx.t('common.backToTimeline')}</a></p>
  </section>`;
  return ok(layout(ctx, { title: nameOf(status.account), me, entrance: !me, legal: !me, body }));
});

// ── プロフィール ────────────────────────────────────────────────
route('GET', '/@:acct', async (ctx) => {
  const t = ctx.t;
  const me = await maybeMe(ctx);
  const q = ctx.url.searchParams;
  const tab = q.get('tab') === 'articles' ? 'articles' : 'posts';
  const maxId = q.get('max_id') ?? undefined;
  const acct = ctx.params.acct;

  let account: Account;
  try {
    account = await gwJson<Account>(ctx, 'GET', '/api/v1/accounts/lookup', { auth: false, query: { acct }, notFound: true });
  } catch (e) {
    if (e instanceof NotFound) {
      return ok(
        layout(ctx, { title: acct, me, entrance: !me, body: html`<p class="error">${t('common.acctNotFound', { acct })}</p><p><a class="chip" href="/timeline">${t('common.backToTimeline')}</a></p>` }),
        404
      );
    }
    throw e;
  }

  const isSelf = me?.id === account.id;
  const [page, pinned, rel] = await Promise.all([
    gwPage<Status>(ctx, `/api/v1/accounts/${encodeURIComponent(account.id)}/statuses`, {
      auth: 'optional',
      query: { limit: '20', max_id: maxId, only_articles: tab === 'articles' ? 'true' : undefined }
    }).catch(() => ({ items: [] as Status[], nextMaxId: null })),
    // ピン留めは、最初の一頁の上にだけ。
    !maxId && tab === 'posts'
      ? gwPage<Status>(ctx, `/api/v1/accounts/${encodeURIComponent(account.id)}/statuses`, { auth: 'optional', query: { pinned: 'true' } }).catch(() => ({ items: [] as Status[], nextMaxId: null }))
      : Promise.resolve({ items: [] as Status[], nextMaxId: null }),
    me && !isSelf
      ? gwJson<Relationship[]>(ctx, 'GET', '/api/v1/accounts/relationships', { query: { 'id[]': account.id } }).then((r) => r[0] ?? null).catch(() => null)
      : Promise.resolve(null)
  ]);

  const base = `/@${account.acct}`;
  const moreHref = page.nextMaxId ? `${base}?${new URLSearchParams({ ...(tab === 'articles' ? { tab } : {}), max_id: page.nextMaxId })}` : null;
  const showHeader = account.header && !account.header.startsWith('data:'); // 無いバナーは 1×1 の透明 PNG で来る
  const fields = account.fields ?? [];
  const replyAccts = await replyAcctsFor(ctx, [...pinned.items, ...page.items]);

  // 数(フォロワー・フォロー・投稿)は出さない。比べないための、引き算。
  const body = html`<header class="profile-head">
      ${showHeader ? html`<img class="profile-header" src="${account.header}" alt="" loading="lazy" />` : ''}
      <div class="profile-id">
        ${avatar(account.avatar, nameOf(account), 'avatar avatar-lg')}
        <div class="stack-tight fill">
          <p class="display-name text-lg">${nameHtml(account)}</p>
          <p class="muted">@${account.acct}</p>
        </div>
        ${rel ? profileActions(ctx, account.id, rel) : ''}
        ${isSelf ? html`<a class="chip" href="/settings">${t('profile.edit')}</a>` : ''}
      </div>
      ${account.roles?.length ? html`<p class="profile-roles">${account.roles.map((r) => html`<span class="role-badge">${r.name}</span>`)}</p>` : ''}
      ${account.note ? html`<div class="profile-note">${raw(renderEmojis(account.note, account.emojis))}</div>` : ''}
      ${account.location || account.birthday || account.created_at
        ? html`<dl class="profile-fields">
            ${account.location ? html`<div class="profile-field"><dt>${t('profile.location')}</dt><dd>${account.location}</dd></div>` : ''}
            ${account.birthday ? html`<div class="profile-field"><dt>${t('profile.birthday')}</dt><dd>${account.birthday}</dd></div>` : ''}
            ${account.created_at ? html`<div class="profile-field"><dt>${t('profile.joined')}</dt><dd>${timeWords(account.created_at, ctx.locale, new Date(), ctx.tz)}</dd></div>` : ''}
          </dl>`
        : ''}
      <p class="profile-links">
        <a class="chip" href="${base}/following">${t('profile.followingSuffix')}</a>
        <a class="chip" href="${base}/followers">${t('profile.followersSuffix')}</a>
      </p>
      ${fields.length
        ? html`<dl class="profile-fields">${fields.map((f) => html`<div class="profile-field"><dt>${f.name}</dt><dd>${raw(renderEmojis(f.value, account.emojis))}</dd></div>`)}</dl>`
        : ''}
    </header>
    <nav class="profile-tabs measure" aria-label="${t('profile.tabsLabel')}">
      <a class="tab ${tab === 'posts' ? 'active' : ''}" href="${base}" aria-current="${tab === 'posts' ? 'true' : null}">${t('profile.tabPosts')}</a>
      <a class="tab ${tab === 'articles' ? 'active' : ''}" href="${base}?tab=articles" aria-current="${tab === 'articles' ? 'true' : null}">${t('profile.tabArticles')}</a>
    </nav>
    <section class="timeline">
      ${pinned.items.length ? html`<p class="pinned-label">${t('profile.pinned')}</p>${pinned.items.map((s) => statusCard(ctx, s, { me, replyAccts }))}` : ''}
      ${page.items.length === 0 && pinned.items.length === 0 ? html`<p class="prose-small">${t('profile.empty')}</p>` : ''}
      ${await statusList(ctx, page.items, { me, idPrefix: 'pf', moreHref })}
    </section>`;

  // 「もっと読む」で続きの断片だけを要求されたときは、外側の枠(ヘッダーやレイアウト)を省いて返す。
  if (ctx.isUp && ctx.upTarget && ctx.upTarget.includes('pf-items:after')) {
    return ok(await statusList(ctx, page.items, { me, idPrefix: 'pf', moreHref }));
  }

  return ok(layout(ctx, { title: nameOf(account), me, entrance: !me, legal: !me, body }));
});

// ── さがす ──────────────────────────────────────────────────────
route('GET', '/search', async (ctx) => {
  const t = ctx.t;
  const me = await maybeMe(ctx);
  if (!me) return ok(layout(ctx, { title: t('search.title'), entrance: true, body: html`<p class="prose-small"><a href="/login">${t('landing.enterTitle')}</a></p>` }), 401);

  const q = (ctx.url.searchParams.get('q') ?? '').trim();
  // 遠くの人(@user@host)なら、WebFinger で取りにいく(数秒かかることがある)。
  const remote = q.replace(/^@/, '').includes('@');
  let result: SearchResult | null = null;
  let rels = new Map<string, Relationship>();
  let error: string | null = null;

  if (q) {
    try {
      result = await gwJson<SearchResult>(ctx, 'GET', '/api/v2/search', { query: { q, resolve: remote ? 'true' : undefined } });
      const ids = result.accounts.map((a) => a.id);
      if (ids.length) {
        const rs = await gwJson<Relationship[]>(ctx, 'GET', '/api/v1/accounts/relationships', { query: { 'id[]': ids } }).catch(() => []);
        rels = new Map(rs.map((r) => [r.id, r]));
      }
    } catch (e) {
      if (!(e instanceof GatewayError)) throw e;
      error = remote ? t('search.errorRemote') : t('search.errorLocal');
    }
  }

  const empty = result && result.accounts.length === 0 && result.hashtags.length === 0;
  const body = html`<header class="timeline page-head"><h1>${t('search.title')}</h1></header>
    <form class="form stack" method="get" action="/search">
      <label class="stack-tight"><span>${t('search.labelPre')}<code>@user@host</code> / <code>#tag</code></span>
        <input type="text" name="q" value="${q}" placeholder="${t('search.placeholder')}" autocapitalize="none" autocorrect="off" spellcheck="false" />
      </label>
      <button type="submit" class="btn px-6 py-2">${t('search.submit')}</button>
    </form>
    ${error ? html`<p class="error">${error}</p>` : ''}
    ${empty
      ? html`<p class="prose-small">${t('search.notFound', { q })} ${remote ? '' : html`${t('search.remoteHintPre')}<code>@user@host</code>${t('search.remoteHintPost')}`}</p>`
      : ''}
    ${result && result.accounts.length
      ? html`<section class="account-list">
          <h2 class="muted" style="font-size: var(--text-sm); margin: var(--space-4) 0 var(--space-2);">${t('search.sectionPeople')}</h2>
          ${result.accounts.map((a) => accountRow(ctx, a, rels.get(a.id) ?? null, me))}
        </section>`
      : ''}
    ${result && result.hashtags.length
      ? html`<section class="account-list" style="margin-top: var(--space-6);">
          <h2 class="muted" style="font-size: var(--text-sm); margin: var(--space-4) 0 var(--space-2);">${t('search.sectionTags')}</h2>
          ${result.hashtags.map((h) => html`<article class="account-row"><a class="account-row-link" href="/tags/${encodeURIComponent(h.name)}"><span class="display-name">#${h.name}</span></a></article>`)}
        </section>`
      : ''}`;
  return ok(layout(ctx, { title: t('search.title'), me, body }));
});

