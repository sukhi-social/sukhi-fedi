// `:shortcode:` を、サーバが持ってきた emojis 配列の画像に差し替える。
// sukhi-fedi 本体の web(lib/emoji.ts)と同じ考え方 ── ただしこちらは
// カスタム絵文字だけ(unicode の Twemoji 化はしない)。

import type { Emoji } from '$lib/api';

// 一つの shortcode が emojis 配列に複数回出てくることがあるので、
// 一括の正規表現置換にする(shortcode ごとに何回も文字列を舐めない)。
export function renderEmojis(html: string, emojis?: Emoji[] | null): string {
  if (!html || !emojis || emojis.length === 0) return html;

  const byShortcode = new Map<string, string>();
  for (const e of emojis) {
    if (!e.shortcode || !e.url) continue;
    if (!byShortcode.has(e.shortcode)) byShortcode.set(e.shortcode, e.url);
  }
  if (byShortcode.size === 0) return html;

  return html.replace(/:([^:\s]+):/g, (token, shortcode: string) => {
    const url = byShortcode.get(shortcode);
    if (!url) return token;
    const src = escapeAttr(url);
    const alt = escapeAttr(token);
    return `<img class="custom-emoji" src="${src}" alt="${alt}" title="${alt}" loading="lazy" />`;
  });
}

function escapeAttr(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}
