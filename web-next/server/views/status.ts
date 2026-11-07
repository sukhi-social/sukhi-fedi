// SPDX-License-Identifier: AGPL-3.0-or-later
// 一枚の投稿。Status.svelte / StatusActions.svelte / StatusMedia.svelte / QuoteCard.svelte の置き換え。
//
// sukhi-web-next との、意図した違いが二つ:
//   ・数を出さない。お気に入り・ブーストの数も、リアクションの数も。「押した」は、かたち(塗り)で。
//   ・時間は、分・秒でなく、うつろいで(time.ts)。
//
// 押す操作は、ふつうの POST フォーム。Unpoly がついていれば、その投稿のところだけを差し替え、
// ついていなければ、頁を戻す(どちらでも、同じ道)。

import { html, raw, type SafeHtml } from '../html.ts';
import type { Ctx } from '../http.ts';
import type { Account, MediaAttachment, Poll, Status } from '../types.ts';
import { renderEmojis } from '../emoji.ts';
import { renderMfm } from '../mfm.ts';
import { phrase } from '../phrase.ts';
import { timeWords } from '../time.ts';
import { avatar, icon } from './parts.ts';
import { translateSlot, type Slot } from './translate.ts';

export type StatusOpts = {
  me: Account | null;
  // 詳細の頁。畳まず、全文を出す。
  full?: boolean;
  // 返信先の acct(in_reply_to_account_id → acct)。引けなかった人は、名前なしの「返信」。
  replyAccts?: Map<string, string>;
  // 押したあとの、ひとこと(「通報しました」など)。
  note?: string;
  // 記事の DOM id。ふだんは st-<id>。ブーストの行のなかでは、元の投稿が
  // 一覧のほかの場所にも並びうるので、重ならない id にする(Unpoly の差し替え先が混ざらないように)。
  domId?: string;
  // 「訳を見る」を押したあとの、訳(か、うまくいかなかった知らせ)。無ければ、ボタンだけ(出るなら)。
  translation?: Slot;
};

const nameOf = (a: Account) => a.display_name || a.acct || a.username;
const nameHtml = (a: Account) => raw(renderEmojis(phrase(nameOf(a)), a.emojis));

function toPlainText(h: string): string {
  return h.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
}

function media(ctx: Ctx, s: Status): SafeHtml {
  const blur = !!s.sensitive && !s.spoiler_text;
  return html`<div class="media" x-data="{ shown: ${String(!blur)}, zoom: null }" :class="{ sensitive: !shown }">
    ${blur ? html`<button type="button" class="media-reveal" x-show="!shown" @click="shown = true">${ctx.t('status.tapToShow')}</button>` : ''}
    ${s.media_attachments.map((m: MediaAttachment) => {
      const label = m.description || '';
      if (m.type === 'image') {
        const src = m.preview_url || m.url;
        return html`<button type="button" class="media-zoom" data-src="${m.url}" @click="zoom = $el.dataset.src" aria-label="${label || ctx.t('status.imageZoom')}"><img src="${src}" alt="${label}" loading="lazy" /></button>`;
      }
      if (m.type === 'video' || m.type === 'gifv') {
        // gifv も自動では動かさない。poster + controls で、押した時だけ。
        return html`<video src="${m.url}" poster="${m.preview_url ?? ''}" controls ${m.type === 'gifv' ? raw('loop muted') : ''} playsinline preload="metadata" aria-label="${label}"></video>`;
      }
      if (m.type === 'audio') return html`<audio src="${m.url}" controls preload="metadata" aria-label="${label}"></audio>`;
      return html`<a class="media-fallback" href="${m.url}" target="_blank" rel="noopener noreferrer">${label || ctx.t('status.openAttachment')}</a>`;
    })}
    <template x-if="zoom">
      <button type="button" class="lightbox" aria-label="${ctx.t('status.close')}" @click="zoom = null" @keydown.escape.window="zoom = null"><img :src="zoom" alt="" /></button>
    </template>
  </div>`;
}

function reactions(ctx: Ctx, s: Status, o: StatusOpts): SafeHtml {
  if (!s.reactions?.length) return html``;
  return html`<div class="reactions" aria-label="${ctx.t('status.reactions')}">
    ${s.reactions.map((r) => {
      const face = r.url ? html`<img class="emoji" src="${r.url}" alt="${r.name}" loading="lazy" />` : html`<span class="emoji">${raw(renderEmojis(r.name))}</span>`;
      // 数は出さない。自分が押したものは、枠の濃さで。
      if (!o.me) return html`<span class="reaction-chip ${r.me ? 'me' : ''}" title="${r.name}">${face}</span>`;
      return html`<form method="post" action="/statuses/${s.id}/react" in-place>
        <input type="hidden" name="emoji" value="${r.name}" />
        <input type="hidden" name="on" value="${r.me ? '0' : '1'}" />
        <button type="submit" class="reaction-chip ${r.me ? 'me' : ''}" title="${r.name}" aria-pressed="${r.me ? 'true' : 'false'}">${face}</button>
      </form>`;
    })}
  </div>`;
}

function actions(ctx: Ctx, s: Status, o: StatusOpts): SafeHtml {
  const t = ctx.t;
  const mine = o.me?.id === s.account.id;
  const post = (verb: string) => `/statuses/${s.id}/${verb}`;
  return html`<footer class="status-actions">
    <form method="post" action="${post(s.favourited ? 'unfavourite' : 'favourite')}" in-place>
      <button type="submit" class="chip ${s.favourited ? 'active' : ''}" aria-pressed="${s.favourited ? 'true' : 'false'}">
        ${icon('star', !!s.favourited)}<span class="visually-hidden">${t('status.favourite')}</span>
      </button>
    </form>
    <span class="boost-wrap" x-data="{ open: false }" @click.outside="open = false" @keydown.escape="open = false" @closemenus.document="open = false">
      <button type="button" class="chip ${s.reblogged ? 'active' : ''}" aria-haspopup="menu" :aria-expanded="open" aria-label="${t('status.boost')}" @click="open = !open">${icon('repeat')}</button>
      <div class="menu boost-menu" role="menu" x-show="open" x-cloak>
        <form method="post" action="${post(s.reblogged ? 'unreblog' : 'reblog')}" in-place>
          <button type="submit" class="menu-item ${s.reblogged ? 'active' : ''}" role="menuitem">${icon('repeat')}<span>${t('status.boost')}</span></button>
        </form>
        <a class="menu-item" role="menuitem" href="/compose?quote=${s.id}">${icon('quote')}<span>${t('status.quote')}</span></a>
      </div>
    </span>
    <a class="chip" href="/compose?reply_to=${s.id}">${t('status.reply')}</a>
    <span class="boost-wrap" x-data="{ open: false }" @click.outside="open = false" @keydown.escape="open = false" @closemenus.document="open = false">
      <button type="button" class="chip" aria-haspopup="menu" :aria-expanded="open" aria-label="${t('status.more')}" @click="open = !open">${icon('more')}</button>
      <div class="menu" role="menu" x-show="open" x-cloak>
        ${mine
          ? html`<form method="post" action="${post('delete')}" in-place up-confirm="${t('status.confirmDelete')}">
              <button type="submit" class="menu-item danger" role="menuitem">${icon('trash')}<span>${t('status.delete')}</span></button>
            </form>`
          : html`<form method="post" action="${post('report')}" in-place>
              <input type="hidden" name="account_id" value="${s.account.id}" />
              <button type="submit" class="menu-item" role="menuitem">${icon('flag')}<span>${t('status.report')}</span></button>
            </form>`}
      </div>
    </span>
    <form method="post" action="${post(s.bookmarked ? 'unbookmark' : 'bookmark')}" in-place>
      <button type="submit" class="chip bookmark ${s.bookmarked ? 'active' : ''}" aria-pressed="${s.bookmarked ? 'true' : 'false'}" aria-label="${s.bookmarked ? t('status.bookmarkRemove') : t('status.bookmarkAdd')}">${icon('bookmark', !!s.bookmarked)}</button>
    </form>
  </footer>`;
}

// 投票。数も、百分率も、目では見せない(棒の長さだけ)。読み上げには割合を添える。
// 投票済み・締め切りは結果の棒、それ以外は選ぶ形。押したあとは、この枠だけが入れ替わる(id が差し替え先)。
export function pollBlock(ctx: Ctx, p: Poll, o: { href: string; remote: boolean; canVote: boolean }): SafeHtml {
  const t = ctx.t;
  const total = Math.max(1, p.votes_count);
  const done = p.expired || !!p.voted;
  const closed = p.expired ? html`<p class="poll-meta">${t('status.pollClosedNote')}</p>` : '';
  const link = !o.canVote
    ? html`<p class="poll-meta"><a href="${o.href}" ${o.remote ? raw('up-follow="false" target="_blank" rel="noopener noreferrer"') : ''}>${t('status.poll')}</a></p>`
    : '';
  if (done) {
    return html`<div class="poll" id="poll-${p.id}" data-in-place aria-label="${t('status.poll')}">
      ${p.options.map((opt, i) => {
        const pct = Math.round(((opt.votes_count ?? 0) / total) * 100);
        const mine = p.own_votes?.includes(i);
        return html`<div class="poll-result ${mine ? 'mine' : ''}">
          <div class="poll-bar" style="width: ${pct}%"></div>
          <span class="poll-label">${opt.title}${mine ? html` <span class="poll-mine">${t('status.pollMine')}</span>` : ''}</span>
          <span class="visually-hidden">${pct}%</span>
        </div>`;
      })}
      ${closed}${link}
    </div>`;
  }
  if (!o.canVote) {
    return html`<div class="poll" id="poll-${p.id}" aria-label="${t('status.poll')}">
      ${p.options.map((opt) => html`<p class="poll-choice"><span>${opt.title}</span></p>`)}${link}
    </div>`;
  }
  return html`<form class="poll" id="poll-${p.id}" data-in-place method="post" action="/polls/${p.id}/vote" in-place aria-label="${t('status.poll')}">
    ${p.options.map(
      (opt, i) => html`<label class="poll-choice"><input type="${p.multiple ? 'checkbox' : 'radio'}" name="choice" value="${i}" ${p.multiple ? '' : raw('required')} /><span>${opt.title}</span></label>`
    )}
    <div><button type="submit" class="chip">${t('status.vote')}</button></div>
  </form>`;
}

function inner(ctx: Ctx, s: Status, o: StatusOpts): SafeHtml {
  const t = ctx.t;
  const a = s.account;
  // 空の lang は「言語不明」になって、UI の言語の継承を切ってしまう。無いときは、付けない。
  const langAttr = s.language && /^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*$/.test(s.language) ? raw(` lang="${s.language}"`) : '';
  const body = raw(s.mfm ? renderMfm(s.mfm, s.emojis) : renderEmojis(s.content, s.emojis));
  const isRemote = a.acct.includes('@');
  const replyAcct = s.in_reply_to_account_id ? o.replyAccts?.get(s.in_reply_to_account_id) : undefined;
  const mediaBlock = s.media_attachments.length > 0 ? media(ctx, s) : '';
  const translation = translateSlot(ctx, s, o.me, o.domId ?? `st-${s.id}`, o.translation);

  return html`<article class="status" id="${o.domId ?? `st-${s.id}`}">
    <a href="/@${a.acct}" tabindex="-1" aria-hidden="true">${avatar(a.avatar, nameOf(a))}</a>
    <div class="body">
      ${s.in_reply_to_id
        ? replyAcct
          ? html`<a class="reply-to" href="/@${replyAcct}/${s.in_reply_to_id}">${icon('reply')} ${t('status.replyTo', { acct: replyAcct })}</a>`
          : html`<span class="reply-to">${icon('reply')} ${t('status.replyToUnknown')}</span>`
        : ''}
      <header class="meta">
        <a class="display-name" href="/@${a.acct}">${nameHtml(a)}</a>
        <a class="handle" href="/@${a.acct}">@${a.acct}</a>
        <span class="sep">·</span>
        <a class="timestamp" href="/@${a.acct}/${s.id}"><time datetime="${s.created_at}">${timeWords(s.created_at, ctx.locale, new Date(), ctx.tz)}</time></a>
        ${isRemote && s.url ? html`<a class="orig" href="${s.url}" target="_blank" rel="noopener noreferrer" title="${t('status.viewOriginal')}" up-follow="false">↗</a>` : ''}
      </header>

      ${s.spoiler_text
        ? html`<details>
            <summary>${s.spoiler_text}</summary>
            <div class="content"${langAttr}>${body}</div>
            ${translation}
            ${mediaBlock}
          </details>`
        : html`<div x-data="collapsible({ full: ${String(!!o.full)} })">
            <div class="content-wrap" :class="{ collapsed: tall && !expanded, reader: ${String(!!o.full)} }">
              <div class="content" x-ref="content"${langAttr}>${body}</div>
            </div>
            ${s.title && !o.full
              ? html`<a class="read-more" href="/@${a.acct}/${s.id}">${t('status.readArticle')}</a>`
              : html`<button type="button" class="read-more" x-show="tall && !expanded" x-cloak @click="expanded = true">${t('status.readMore')}</button>`}
          </div>
          ${translation}`}

      ${s.quote
        ? html`<a class="quote-card" href="/@${s.quote.account.acct}/${s.quote.id}">
            <div class="quote-head">
              ${avatar(s.quote.account.avatar, nameOf(s.quote.account), 'quote-avatar')}
              <span class="quote-name">${nameHtml(s.quote.account)}</span>
              <span class="quote-acct">@${s.quote.account.acct}</span>
            </div>
            <div class="quote-content">${raw(renderEmojis(s.quote.content, s.quote.emojis))}</div>
          </a>`
        : ''}

      ${s.spoiler_text ? '' : mediaBlock}

      ${s.poll ? pollBlock(ctx, s.poll, { href: s.url ?? `/@${a.acct}/${s.id}`, remote: !!s.url, canVote: !!o.me }) : ''}

      ${s.card && s.media_attachments.length === 0 && !s.quote
        ? html`<a class="preview-card" href="${s.card.url}" target="_blank" rel="noopener noreferrer nofollow" up-follow="false">
            ${s.card.image ? html`<img class="preview-image" src="${s.card.image}" alt="" loading="lazy" />` : ''}
            <span class="preview-body">
              ${s.card.title ? html`<span class="preview-title">${s.card.title}</span>` : ''}
              ${s.card.description ? html`<span class="preview-desc muted">${s.card.description}</span>` : ''}
            </span>
          </a>`
        : ''}

      ${reactions(ctx, s, o)}
      ${o.me ? actions(ctx, s, o) : ''}
      ${o.note ? html`<p class="muted status-note" role="status">${o.note}</p>` : ''}
    </div>
  </article>`;
}

// ブーストの行のなかの元の投稿の id。st-<元の id> とは別にして、
// 同じ投稿が一覧に単独でも並んでいるとき、どちらを差し替えるかが混ざらないようにする。
export const boostInnerId = (boostId: string) => `bst-${boostId}-inner`;

export function statusCard(ctx: Ctx, s: Status, o: StatusOpts): SafeHtml {
  if (!s.reblog) return inner(ctx, s, o);
  // ブーストは、ふだん一行に畳む(元の投稿が埋もれないように)。左から:
  //   ブーストした人のアイコン、(ブーストした人の名前 ── 設定で隠せる)、ブーストの印、
  //   ブーストされた人のアイコン、二行までの内容。
  // 文は出さない代わりに、読み上げには一文で(「○○が、△△の投稿をブースト」)。
  // 開くと、元の投稿が続く。<details> なので、JS が無くても開ける。
  const booster = s.account;
  const author = s.reblog.account;
  const hideName = !!o.me?.source?.boost_hide_name;
  const said = hideName
    ? ctx.t('status.boostSummaryHidden', { who: nameOf(author) })
    : ctx.t('status.boostSummary', { by: nameOf(booster), who: nameOf(author) });
  // 画像があるとき、アイコンと同じ高さの四角いプレビューを添える。
  // 本文に CW がある、または画像が sensitive のときは、出さない(開くまで隠す)。
  const firstImage = s.reblog.media_attachments.find((m) => m.type === 'image');
  const thumb = firstImage && !s.reblog.spoiler_text && !s.reblog.sensitive ? firstImage.preview_url || firstImage.url : '';
  // 「(ブーストした人)さんがブーストしました」。名前だけがプロフィールへのリンク。
  const [pre = '', post = ''] = ctx.t('status.boostedLine', { by: '\u0000' }).split('\u0000');
  const boostedLine = html`${pre}<a class="boost-by-name" href="/@${booster.acct}">${nameHtml(booster)}</a>${post}`;
  return html`<details class="boost" id="bst-${s.id}">
    <summary class="boost-compact" title="${ctx.t('status.expandBoost')}">
      <span class="visually-hidden">${said}</span>
      <span class="boost-row-art" aria-hidden="true">${avatar(booster.avatar, nameOf(booster), 'quote-avatar')}</span>
      ${hideName ? '' : html`<span class="boost-row-who" aria-hidden="true">${nameHtml(booster)}</span>`}
      <span class="boost-row-mark" aria-hidden="true">${icon('repeat')}</span>
      <span class="boost-row-art" aria-hidden="true">${avatar(author.avatar, nameOf(author), 'quote-avatar')}</span>
      ${thumb ? html`<img class="boost-row-thumb" src="${thumb}" alt="" loading="lazy" aria-hidden="true" />` : ''}
      <span class="boost-compact-preview">${raw(renderEmojis(phrase(toPlainText(s.reblog.content)), s.reblog.emojis))}</span>
    </summary>
    <p class="boost-by">${icon('repeat')} ${boostedLine}</p>
    ${inner(ctx, s.reblog, { ...o, domId: boostInnerId(s.id) })}
  </details>`;
}

// 一覧の「終わりの印」。無限スクロールの代わりに、ここで終わると言う。
export function theEnd(ctx: Ctx): SafeHtml {
  return html`<p class="the-end" role="note">${ctx.t('end.here')}</p>`;
}
