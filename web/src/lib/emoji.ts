// Swap Mastodon `:shortcode:` tokens for the custom-emoji images the
// server advertises in a status/account `emojis` array. Misskey and
// Mastodon both send these; without the substitution a remote name, bio
// or post shows the literal `:blobcat:`.

import type { Emoji } from './api';
import twemoji from '@twemoji/api';

// Self-hosted Twemoji (copied into static/twemoji/svg at build). Pointing the
// parser here keeps unicode emoji consistent across platforms without a CDN.
const TWEMOJI_OPTS = { base: '/twemoji/', folder: 'svg', ext: '.svg', className: 'twemoji' };

// `html` is assumed to already be safe — server-rendered status/bio HTML,
// or text that went through `phrase()`. We only inject our own <img> and
// escape the url/shortcode we put into attributes.
//
// Replacement is a single pass over the text, not one pass per emoji:
// some peers send one Emoji tag per *occurrence*, so the array can hold
// the same shortcode twice — a second pass would then match the
// `alt=":x:"` inside the <img> the first pass inserted and nest broken
// markup. First entry wins.
export function renderEmojis(html: string, emojis?: Emoji[] | null): string {
  if (!html) return html;

  const byShortcode = new Map<string, string>();
  for (const e of emojis ?? []) {
    if (!e.shortcode || !e.url) continue;
    if (!byShortcode.has(e.shortcode)) byShortcode.set(e.shortcode, e.url);
  }

  let out = html;
  if (byShortcode.size > 0) {
    out = out.replace(/:([^:\s]+):/g, (token, shortcode) => {
      const normalized = shortcode.endsWith('@.') ? shortcode.slice(0, -2) : shortcode;
      const url = byShortcode.get(shortcode) || byShortcode.get(normalized);
      if (!url) return token;
      const src = escapeAttr(url);
      const alt = escapeAttr(token);
      return `<img class="custom-emoji" src="${src}" alt="${alt}" title="${alt}" loading="lazy" />`;
    });
  }

  // Then unicode emoji → Twemoji images. Custom-emoji <img> we just inserted
  // carry no unicode, so they're left alone.
  return twemoji.parse(out, TWEMOJI_OPTS);
}

// The self-hosted URL for a single emoji char — for fixed UI icons (boost,
// favourite, …) rendered outside the HTML-content path. Let the parser pick
// the canonical filename so the FE0F variation selector, ZWJ sequences and
// keycaps resolve the same way they do in content.
export function twemojiUrl(emoji: string): string {
  const m = twemoji.parse(emoji, TWEMOJI_OPTS).match(/src="([^"]+)"/);
  return m ? m[1] : '';
}

function escapeAttr(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}
