// SPDX-License-Identifier: AGPL-3.0-or-later
// Clips の一枚。自分あての会話(自分だけの部屋)に置いた、メモ・URL・画像・ファイル。
//
//   ・相手は常に自分なので、名前もアバターも出さない。時刻だけ(いつ置いたか、は要る情報)。
//   ・ピンは、リアクションの 📌(自分が、自分の投稿に)。押すのは、ふつうのリアクションと同じ道(POST /statuses/:id/react)。
//   ・文字があるときだけ「コピー」。コピーする字は、ここで組んで data-copy に持たせる(手元の DOM から読み直さない)。
//   ・画像でない添付は、中身を見せず、ファイルであることと、名前・拡張子だけ。

import { html, raw, type SafeHtml } from '../html.ts';
import type { Ctx } from '../http.ts';
import { renderEmojis } from '../emoji.ts';
import { timeWords } from '../time.ts';
import type { Account, MediaAttachment, Status } from '../types.ts';
import { icon } from './parts.ts';

export const PIN = '📌';

export const isPinned = (s: Status): boolean => !!s.reactions?.some((r) => r.name === PIN && r.me);

// ── 宛名を外す ──
// DM の宛先は本文の @ 言及で決まる(gateway の約束)ので、どの一通も自分の名前で始まる(web の書きかたは、末尾に回す)。
// 読む文ではなく宛名なので、表示のときだけ外す。外すのは「先頭の言及」と「言及だけの末尾の段落」。文中の言及は、触らない。

// 末尾が「言及だけの段落」なら、その段落ごと落とす。文が混じっていれば、それは書き手が書いたもの。
function withoutTrailingAddress(s: string): string {
  if (!/<\/p>\s*$/i.test(s)) return s;
  const start = s.toLowerCase().lastIndexOf('<p');
  if (start <= 0) return s; // 段落が一つだけなら、先頭側の規則に任せる
  const open = s.indexOf('>', start);
  if (open < 0) return s;
  const inner = s.slice(open + 1, s.toLowerCase().lastIndexOf('</p>'));
  if (!inner.includes('@')) return s;
  const bare = inner
    .replace(/<[^>]+>/g, '')
    .replace(/@[\w.-]+(?:@[\w.-]+)?/gu, '')
    .replace(/[\s　]/gu, '');
  return bare === '' ? s.slice(0, start) : s;
}

export function withoutAddress(content: string | null | undefined): string {
  const s = withoutTrailingAddress(String(content ?? ''));
  const open = /^\s*<p[^>]*>/i.exec(s);
  if (!open) return s;
  const head = open[0];
  let i = head.length;

  // h-card は入れ子(<span class="h-card"><a>@<span>acct</span></a></span>)。span の開閉を数えて、閉じるところを探す。
  const closeSpanFrom = (from: number): number => {
    let depth = 0;
    const tag = /<(\/?)span\b[^>]*>/giu;
    tag.lastIndex = from;
    let m: RegExpExecArray | null;
    while ((m = tag.exec(s))) {
      depth += m[1] ? -1 : 1;
      if (depth === 0) return tag.lastIndex;
    }
    return -1;
  };

  for (;;) {
    const at = i + (/^\s*/u.exec(s.slice(i))?.[0].length ?? 0);
    if (/^<span class="h-card"/i.test(s.slice(at))) {
      const end = closeSpanFrom(at);
      if (end < 0) break;
      i = end;
      continue;
    }
    // h-card に包まれていない素の言及も、あたまなら落とす。
    const bare = /^@[\w.-]+(?:@[\w.-]+)?/u.exec(s.slice(at));
    if (bare) {
      i = at + bare[0].length;
      continue;
    }
    i = at;
    break;
  }
  return i === head.length ? s : head + s.slice(i);
}

// 本文を、貼りつけられる字に。段落・改行は改行に、タグは外す。リンクは、省略されない全文のまま(見えない部分も含む)。
const ENTITIES: Record<string, string> = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'", '&#x27;': "'", '&nbsp;': ' ' };
export function copyText(body: string): string {
  return body
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>\s*<p[^>]*>/gi, '\n\n')
    .replace(/<[^>]*>/g, '')
    .replace(/&(?:amp|lt|gt|quot|#39|#x27|nbsp);/g, (e) => ENTITIES[e] ?? e)
    .trim();
}

// ── 添付 ──────────────────────────────────────────────────────────
function attachment(ctx: Ctx, m: MediaAttachment): SafeHtml {
  if (m.type === 'image') {
    const label = m.description || '';
    return html`<a class="clip-image" href="${m.url}" target="_blank" rel="noopener noreferrer"><img src="${m.preview_url || m.url}" alt="${label}" loading="lazy" /></a>`;
  }
  // 画像でないもの。名前は uploader が付けたまま(無ければ file)。拡張子は、名前の最後の点から。
  const name = m.filename || ctx.t('clips.file');
  const dot = name.lastIndexOf('.');
  const ext = dot > 0 ? name.slice(dot + 1).toUpperCase() : '';
  return html`<a class="clip-file" href="${m.url}" target="_blank" rel="noopener noreferrer" download="${name}">
    <span class="clip-ext" aria-hidden="true">${ext || '?'}</span><span class="clip-fname">${name}</span>
  </a>`;
}

// ── 一枚 ──────────────────────────────────────────────────────────
// id が clip-<id> で、data-in-place ── ピンやリアクションを押すと、この一枚だけが、押したあとの姿で差しかわる。
export function clipCard(ctx: Ctx, me: Account, s: Status): SafeHtml {
  const t = ctx.t;
  const pinned = isPinned(s);
  const body = withoutAddress(s.content);
  const text = copyText(body);
  const others = (s.reactions ?? []).filter((r) => r.name !== PIN);
  const dom = `clip-${s.id}`;
  const chip = (name: string, url?: string | null) =>
    url ? html`<img class="emoji" src="${url}" alt="${name}" loading="lazy" />` : html`<span class="emoji">${raw(renderEmojis(name))}</span>`;
  const label = pinned ? t('clips.unpin') : t('clips.pin');

  return html`<article class="clip" id="${dom}" data-in-place>
    <header class="clip-head"><a class="clip-when" href="/@${s.account.acct}/${s.id}"><time datetime="${s.created_at}">${timeWords(s.created_at, ctx.locale, new Date(), ctx.tz)}</time></a></header>
    ${s.spoiler_text
      ? html`<details><summary>${s.spoiler_text}</summary><div class="clip-body content">${raw(renderEmojis(body, s.emojis))}</div></details>`
      : text ? html`<div class="clip-body content">${raw(renderEmojis(body, s.emojis))}</div>` : ''}
    ${s.media_attachments.length ? html`<div class="clip-media">${s.media_attachments.map((m) => attachment(ctx, m))}</div>` : ''}
    <div class="reactions clip-reactions">
      <form method="post" action="/statuses/${s.id}/react" in-place>
        <input type="hidden" name="emoji" value="${PIN}" />
        <input type="hidden" name="on" value="${pinned ? '0' : '1'}" />
        <button type="submit" class="reaction-chip pin-toggle ${pinned ? 'me' : ''}" aria-pressed="${pinned ? 'true' : 'false'}" title="${label}" aria-label="${label}">${icon('pin', pinned)}</button>
      </form>
      ${text
        ? html`<button type="button" class="reaction-chip copy-toggle" data-copy="${text}" data-copy-label="${t('clips.copy')}" data-copied="${t('clips.copied')}" x-data="{ done: false }"
            @click="navigator.clipboard.writeText($root.dataset.copy).then(() => { done = true; setTimeout(() => (done = false), 1600) }).catch(() => {})"
            :title="done ? $root.dataset.copied : $root.dataset.copyLabel" aria-label="${t('clips.copy')}">
            <span class="emoji" x-show="!done">${raw(renderEmojis('📋'))}</span><span class="emoji" x-show="done" x-cloak>${raw(renderEmojis('✅'))}</span>
            <span class="visually-hidden" role="status" x-text="done ? $root.dataset.copied : ''"></span>
          </button>`
        : ''}
      ${others.map(
        (r) => html`<form method="post" action="/statuses/${s.id}/react" in-place>
          <input type="hidden" name="emoji" value="${r.name}" />
          <input type="hidden" name="on" value="${r.me ? '0' : '1'}" />
          <button type="submit" class="reaction-chip ${r.me ? 'me' : ''}" title="${r.name}" aria-pressed="${r.me ? 'true' : 'false'}">${chip(r.name, r.url)}</button>
        </form>`
      )}
      <a class="reaction-chip reaction-add" href="/statuses/${s.id}/react?d=${dom}" up-target="#rp-${dom}" up-history="false" up-scroll="false" title="${t('status.reactAdd')}" aria-label="${t('status.reactAdd')}">${icon('smile')}</a>
    </div>
    <div id="rp-${dom}"></div>
  </article>`;
}
