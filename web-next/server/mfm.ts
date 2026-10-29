// SPDX-License-Identifier: AGPL-3.0-or-later
// Render the STATIC subset of MFM (Misskey Flavored Markdown) to safe HTML.
//
// Misskey-family notes federate their MFM source out of band (notes.mfm,
// from `_misskey_content` / `source.content`); the rendered `content` HTML a
// Mastodon server would produce flattens the formatting. When we hold the
// source we render it ourselves so bold/quote/code survive — but we render
// only the *static* subset. MFM's motion functions ($[spin], $[shake],
// $[jelly], $[rainbow], $[tada], $[twitch], …) are calm-UX poison: their
// inner text is kept, their animation wrapper is dropped entirely.
//
// XSS safety follows the same property as phrase()/renderEmojis: escape the
// whole source FIRST (escapeHtml, the one named text-escape predicate), then
// apply formatting. After the escape the only `<` in the working string are
// the tags this module inserts itself, so no user input can open a tag or
// break out of an attribute. There is no unescaped {@html} path here.

import type { Emoji } from './types.ts';
import { renderEmojis } from './emoji.ts';
import { escapeHtml } from './phrase.ts';

// Turn MFM source into safe HTML for the static subset. The caller passes
// the same `emojis` array it would hand renderEmojis for the content path,
// so :shortcode: custom emoji resolve identically.
export function renderMfm(source: string, emojis?: Emoji[] | null): string {
  if (!source) return '';

  // 1. Escape everything once. From here the string is HTML-safe text; the
  //    only markup is what we add below.
  let html = escapeHtml(source);

  // 2. Motion/decoration functions: keep the inner text, drop the wrapper.
  //    $[name ...] and $[name.opt ...] both collapse to their content. We
  //    strip from the innermost outward so nested wrappers all unwrap.
  html = stripFunctions(html);

  // 3. Block-level structure, line-anchored, before inline marks.
  html = formatBlocks(html);

  // 4. Inline marks. Code spans first so their contents aren't re-marked.
  html = formatInline(html);

  // 5. MFM is whitespace-significant; the surviving newlines become <br>.
  //    A <pre> keeps its own newlines (the element renders them), so its
  //    body is held out of this pass.
  html = newlinesToBreaks(html);

  // 6. Custom + unicode emoji, on already-safe HTML (renderEmojis' contract).
  return renderEmojis(html, emojis);
}

// $[fn content] → content. The function name (with optional .args) is the
// run of non-space chars after `$[`; everything up to the matching `]` is
// kept. We find the innermost `$[ … ]` (one with no `$[` inside) and unwrap
// it, looping until none remain — so $[x $[y z]] fully flattens.
const INNERMOST_FN = /\$\[[^\s\]]+\s+([^$\]]*)\]/;

function stripFunctions(html: string): string {
  let out = html;
  // Bound the loop by the bracket count so a malformed `$[` can't spin.
  let guard = (out.match(/\$\[/g) || []).length + 1;
  while (guard-- > 0 && INNERMOST_FN.test(out)) {
    out = out.replace(INNERMOST_FN, '$1');
  }
  return out;
}

// Fenced code blocks (``` … ```), then blockquotes (lines led by `>`),
// then center. These read the escaped text line by line.
function formatBlocks(html: string): string {
  // ```lang\n … \n``` → <pre><code>…</code></pre>. The body is already
  // escaped; we only strip the fence lines and an optional language tag.
  html = html.replace(/```[^\n]*\n([\s\S]*?)\n?```/g, (_m, body) => {
    return `<pre><code>${body}</code></pre>`;
  });

  // <center> … </center> is an MFM block (it arrives escaped). Center is
  // static layout, not motion, so it stays.
  html = html.replace(/&lt;center&gt;([\s\S]*?)&lt;\/center&gt;/g, (_m, inner) => {
    return `<div class="mfm-center">${inner}</div>`;
  });

  // Blockquotes: runs of consecutive lines starting with `&gt;` (an escaped
  // `>`). One `<blockquote>` per run; the marker and one optional space go.
  html = html.replace(/(?:^|\n)((?:&gt;[^\n]*(?:\n|$))+)/g, (_m, block) => {
    const inner = block
      .replace(/\n$/, '')
      .split('\n')
      .map((line: string) => line.replace(/^&gt; ?/, ''))
      .join('\n');
    return `\n<blockquote>${inner}</blockquote>`;
  });

  return html;
}

// Replace literal newlines with <br>, except inside a <pre>…</pre> where the
// element already preserves them. The block builders left a leading newline
// before <blockquote>; we let those collapse around the tag rather than
// emit an empty <br> line, by trimming a newline that sits next to a block tag.
function newlinesToBreaks(html: string): string {
  const parts = html.split(/(<pre>[\s\S]*?<\/pre>)/);
  return parts
    .map((part, i) => {
      // Odd indexes are the captured <pre> blocks — left verbatim.
      if (i % 2 === 1) return part;
      return part
        .replace(/\n*(<\/?(?:blockquote|pre|div)[^>]*>)\n*/g, '$1')
        .replace(/\n/g, '<br />');
    })
    .join('');
}

function formatInline(html: string): string {
  // Inline code: `code` → <code>code</code>. Done first so the marks below
  // don't reach inside a code span.
  html = html.replace(/`([^`\n]+)`/g, '<code>$1</code>');

  // MFM HTML-tag marks (escaped on the way in). Map each to a plain element.
  // <small> shrinks, the rest are weight/slant/strike — all static.
  html = html.replace(/&lt;small&gt;([\s\S]*?)&lt;\/small&gt;/g, '<small>$1</small>');
  html = html.replace(/&lt;b&gt;([\s\S]*?)&lt;\/b&gt;/g, '<strong>$1</strong>');
  html = html.replace(/&lt;i&gt;([\s\S]*?)&lt;\/i&gt;/g, '<em>$1</em>');
  html = html.replace(/&lt;s&gt;([\s\S]*?)&lt;\/s&gt;/g, '<del>$1</del>');

  // Markdown-flavoured marks.
  html = html.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
  html = html.replace(/__([^_\n]+)__/g, '<strong>$1</strong>');
  html = html.replace(/\*([^*\n]+)\*/g, '<em>$1</em>');
  html = html.replace(/(^|[^a-zA-Z0-9])_([^_\n]+)_(?=$|[^a-zA-Z0-9])/g, '$1<em>$2</em>');
  html = html.replace(/~~([^~\n]+)~~/g, '<del>$1</del>');

  // [label](url) markdown links, then bare URLs, then mentions/hashtags.
  html = formatLinks(html);

  return html;
}

// Only http(s) URLs become links — escapeHtml already neutralised quotes and
// angle brackets, and we additionally reject anything that isn't a plain
// http(s) URL so no `javascript:`-style scheme reaches an href. The captured
// url is already HTML-safe text (post-escape), so it goes straight into the
// attribute.
const URL_RE = /\bhttps?:\/\/[^\s<>"']+/g;

function formatLinks(html: string): string {
  // [label](http…) → <a>label</a>. Label keeps any inline marks already
  // applied; the url must be http(s).
  html = html.replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, (_m, label, url) => {
    return `<a href="${url}" rel="nofollow noopener" target="_blank">${label}</a>`;
  });

  // Bare URLs. Skip ones already inside an href="…" we just wrote by only
  // matching when not preceded by `"` (the attribute quote) or `>`.
  html = html.replace(URL_RE, (url, offset: number, whole: string) => {
    const prev = offset > 0 ? whole[offset - 1] : '';
    if (prev === '"' || prev === '>') return url;
    return `<a href="${url}" rel="nofollow noopener" target="_blank">${url}</a>`;
  });

  // Mentions: @user or @user@host → link to the local profile route the rest
  // of the app uses (/@acct). Must not fire inside an email or an href.
  html = html.replace(
    /(^|[^\w@/"])@([a-zA-Z0-9_]+(?:@[a-zA-Z0-9.-]+)?)/g,
    (_m, lead, acct) => `${lead}<a href="/@${acct}" class="mention">@${acct}</a>`
  );

  // Hashtags: #tag → the local tag timeline (rel="tag", matching server
  // content). Not inside a word and not a bare `#`.
  html = html.replace(
    /(^|[^\w&/"])#([\p{L}\p{N}_]+)/gu,
    (_m, lead, tag) => `${lead}<a href="/tags/${tag}" rel="tag" class="hashtag">#${tag}</a>`
  );

  return html;
}
