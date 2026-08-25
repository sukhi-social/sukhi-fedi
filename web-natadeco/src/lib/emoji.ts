// `:shortcode:` を、サーバが持ってきた emojis 配列の画像に差し替えて、
// そのあと素の unicode 絵文字を Twemoji の絵に差し替える。
// sukhi-fedi 本体の web(lib/emoji.ts)と同じ形。
//
// Twemoji は CDN からではなく自前で持つ ── 読む人のブラウザを、
// よその家に取りに行かせない。`scripts/copy-twemoji.mjs` が
// `@twemoji/svg` を build 前に `static/twemoji/svg` へ写す。

import type { Emoji } from '$lib/api';
import twemoji from '@twemoji/api';

const TWEMOJI_OPTS = { base: '/twemoji/', folder: 'svg', ext: '.svg', className: 'twemoji' };

// 一つの shortcode が emojis 配列に複数回出てくることがあるので、
// 一括の正規表現置換にする(shortcode ごとに何回も文字列を舐めない)。
export function renderEmojis(html: string, emojis?: Emoji[] | null): string {
  if (!html) return html;

  const byShortcode = new Map<string, string>();
  for (const e of emojis ?? []) {
    if (!e.shortcode || !e.url) continue;
    if (!byShortcode.has(e.shortcode)) byShortcode.set(e.shortcode, e.url);
  }

  let out = html;
  if (byShortcode.size > 0) {
    out = out.replace(/:([^:\s]+):/g, (token, shortcode: string) => {
      const url = byShortcode.get(shortcode);
      if (!url) return token;
      const src = escapeAttr(url);
      const alt = escapeAttr(token);
      return `<img class="custom-emoji" src="${src}" alt="${alt}" title="${alt}" loading="lazy" />`;
    });
  }

  // unicode は最後。順番が逆だと、差し込んだ <img> の alt(`:x:`)を
  // カスタム絵文字の置換がもう一度舐めて、壊れた入れ子になる。
  return twemoji.parse(out, TWEMOJI_OPTS);
}

/**
 * 素のテキスト一片を、Twemoji を通してから返す。反応のチップのように
 * 「サーバから来た文字列をそのまま出す」ところ用。
 *
 * `twemoji.parse` は絵文字以外をそのまま通すので、先に escape する ──
 * 反応の名前は連合越しに他所のサーバから届きうる。
 */
export function renderGlyph(text: string): string {
  return twemoji.parse(escapeAttr(text), TWEMOJI_OPTS);
}

function escapeAttr(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}
