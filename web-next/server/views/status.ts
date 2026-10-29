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
import type { Account, MediaAttachment, Status } from '../types.ts';
import { renderEmojis } from '../emoji.ts';
import { renderMfm } from '../mfm.ts';
import { phrase } from '../phrase.ts';
import { timeWords } from '../time.ts';
import { avatar, icon } from './parts.ts';

export type StatusOpts = {
  me: Account | null;
  // 詳細の頁。畳まず、全文を出す。
  full?: boolean;
  // 返信先の acct(in_reply_to_account_id → acct)。引けなかった人は、名前なしの「返信」。
  replyAccts?: Map<string, string>;
  // 押したあとの、ひとこと(「通報しました」など)。
  note?: string;
};

const nameOf = (a: Account) => a.display_name || a.username;
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

function inner(ctx: Ctx, s: Status, o: StatusOpts): SafeHtml {
  const t = ctx.t;
  const a = s.account;
  // 空の lang は「言語不明」になって、UI の言語の継承を切ってしまう。無いときは、付けない。
  const langAttr = s.language && /^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*$/.test(s.language) ? raw(` lang="${s.language}"`) : '';
  const body = raw(s.mfm ? renderMfm(s.mfm, s.emojis) : renderEmojis(s.content, s.emojis));
  const isRemote = a.acct.includes('@');
  const replyAcct = s.in_reply_to_account_id ? o.replyAccts?.get(s.in_reply_to_account_id) : undefined;
  const mediaBlock = s.media_attachments.length > 0 ? media(ctx, s) : '';

  return html`<article class="status" id="st-${s.id}">
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
        <a class="timestamp" href="/@${a.acct}/${s.id}"><time datetime="${s.created_at}">${timeWords(s.created_at, ctx.locale)}</time></a>
        ${isRemote && s.url ? html`<a class="orig" href="${s.url}" target="_blank" rel="noopener noreferrer" title="${t('status.viewOriginal')}" up-follow="false">↗</a>` : ''}
      </header>

      ${s.spoiler_text
        ? html`<details>
            <summary>${s.spoiler_text}</summary>
            <div class="content"${langAttr}>${body}</div>
            ${mediaBlock}
          </details>`
        : html`<div x-data="collapsible({ full: ${String(!!o.full)} })">
            <div class="content-wrap" :class="{ collapsed: tall && !expanded, reader: ${String(!!o.full)} }">
              <div class="content" x-ref="content"${langAttr}>${body}</div>
            </div>
            ${s.title && !o.full
              ? html`<a class="read-more" href="/@${a.acct}/${s.id}">${t('status.readArticle')}</a>`
              : html`<button type="button" class="read-more" x-show="tall && !expanded" x-cloak @click="expanded = true">${t('status.readMore')}</button>`}
          </div>`}

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

      ${s.poll
        ? html`<div class="poll" aria-label="${t('status.poll')}">
            ${s.poll.options.map((opt) => html`<p class="poll-choice"><span>${opt.title}</span></p>`)}
            <p class="poll-meta"><a href="${s.url ?? `/@${a.acct}/${s.id}`}" ${s.url ? raw('up-follow="false" target="_blank" rel="noopener noreferrer"') : ''}>${t('status.poll')}</a></p>
          </div>`
        : ''}

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

export function statusCard(ctx: Ctx, s: Status, o: StatusOpts): SafeHtml {
  if (!s.reblog) return inner(ctx, s, o);
  // ブーストは、ふだん一行に畳む(元の投稿が埋もれないように)。開くと「○○がブースト」+ 元の投稿。
  // <details> なので、JS が無くても開ける。
  const by = nameHtml(s.account);
  return html`<details class="boost" id="bst-${s.id}">
    <summary class="boost-compact" title="${ctx.t('status.expandBoost')}">
      ${avatar(s.reblog.account.avatar, nameOf(s.reblog.account), 'quote-avatar')}
      <span class="boost-compact-by">${icon('repeat')} ${by} ${ctx.t('status.boostedBy')}</span>
      <span class="boost-compact-preview">${raw(renderEmojis(phrase(toPlainText(s.reblog.content)), s.reblog.emojis))}</span>
    </summary>
    <a class="boost-by" href="/@${s.account.acct}">${icon('repeat')} ${by} ${ctx.t('status.boostedBy')}</a>
    ${inner(ctx, s.reblog, o)}
  </details>`;
}

// 一覧の「終わりの印」。無限スクロールの代わりに、ここで終わると言う。
export function theEnd(ctx: Ctx): SafeHtml {
  return html`<p class="the-end" role="note">${ctx.t('end.here')}</p>`;
}
