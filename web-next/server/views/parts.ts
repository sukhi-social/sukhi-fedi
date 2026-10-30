// SPDX-License-Identifier: AGPL-3.0-or-later
// 頁をまたいで使う、小さな部品。アイコン、アバター、入口の帯、法的ページへの入り口、言語の窓。

import { config } from '../config.ts';
import { html, raw, type SafeHtml } from '../html.ts';
import { avatarColor, avatarInitial, isDefaultAvatar } from '../avatar.ts';
import { LOCALES, LOCALE_NAMES, type Locale } from '../i18n.ts';
import type { Ctx } from '../http.ts';

// ── 線画のアイコン(NavIcon.svelte と同じ形。currentColor、色は持たない)────
export type IconName =
  | 'home' | 'bell' | 'search' | 'compose' | 'user' | 'logout' | 'plus'
  | 'star' | 'repeat' | 'quote' | 'reply' | 'more' | 'trash' | 'flag' | 'bookmark' | 'pin' | 'image';

const PATHS: Record<IconName, string> = {
  home: '<path d="M3.5 11.5 12 4l8.5 7.5" /><path d="M6 10v9.5h12V10" />',
  bell: '<path d="M6 17c1.2-1.5 1.5-3.5 1.5-6a4.5 4.5 0 0 1 9 0c0 2.5.3 4.5 1.5 6Z" /><path d="M10 20a2 2 0 0 0 4 0" />',
  search: '<circle cx="11" cy="11" r="6.5" /><path d="M16 16 20.5 20.5" />',
  compose: '<path d="M14.5 5.5 18.5 9.5 9 19l-4.2 1.2L6 16Z" /><path d="M13.5 6.5 17.5 10.5" />',
  user: '<circle cx="12" cy="8.5" r="3.5" /><path d="M5.5 19.5a6.5 6.5 0 0 1 13 0" />',
  logout: '<path d="M14 4H6v16h8" /><path d="M10 12h10M16.5 8.5 20 12l-3.5 3.5" />',
  plus: '<path d="M12 5.5v13M5.5 12h13" />',
  star: '<path d="M12 4 14.3 9.2 20 9.8 15.7 13.7 17 19.3 12 16.4 7 19.3 8.3 13.7 4 9.8 9.7 9.2Z" />',
  repeat:
    '<path d="M4 11V9.5A3.5 3.5 0 0 1 7.5 6H20" /><path d="M17 3l3 3-3 3" /><path d="M20 13v1.5a3.5 3.5 0 0 1-3.5 3.5H4" /><path d="M7 21l-3-3 3-3" />',
  quote: '<path d="M4.5 5.5h15v10h-9l-4.5 3.5v-3.5h-1.5Z" />',
  reply: '<path d="M9.5 8 5 12.5 9.5 17" /><path d="M5 12.5h8.5a5.5 5.5 0 0 1 5.5 5.5" />',
  more: '<circle cx="5.5" cy="12" r="1.4" fill="currentColor" stroke="none" /><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none" /><circle cx="18.5" cy="12" r="1.4" fill="currentColor" stroke="none" />',
  trash: '<path d="M5 7h14M10 7V5h4v2M7 7l1 12.5h8L17 7" />',
  flag: '<path d="M6 20.5V4.5" /><path d="M6 5h11l-2.2 3.5L17 12H6" />',
  bookmark: '<path d="M7 4.5h10v15l-5-4-5 4Z" />',
  pin: '<path d="M9 4.5h6l-1 5 2.5 2.5v1.5h-9V12L10 9.5Z" /><path d="M12 13.5V20" />',
  image: '<rect x="3.5" y="5" width="17" height="14" rx="2" /><circle cx="8.5" cy="10" r="1.4" /><path d="M4 17l4.5-4.5L12 16l3-3 5 5" />'
};

// 押している状態を、色だけでなく「かたち」(塗りつぶし)でも。
export function icon(name: IconName, filled = false): SafeHtml {
  return raw(
    `<svg class="nav-ico" viewBox="0 0 24 24" fill="${filled ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${PATHS[name]}</svg>`
  );
}

// ── アバター ──────────────────────────────────────────────────────
// 画像が無い人は、頭文字と名前ごとの淡い色。
export function avatar(src: string | null | undefined, name: string, cls = 'avatar'): SafeHtml {
  if (isDefaultAvatar(src)) {
    const c = avatarColor(name);
    return html`<span class="${cls}" data-avatar-fallback style="background: ${c.bg}; color: ${c.fg};" aria-hidden="true">${avatarInitial(name)}</span>`;
  }
  return html`<img class="${cls}" src="${src}" alt="" loading="lazy" />`;
}

// ── 入る前の画面の、いちばん上の帯 ───────────────────────────────
export function entranceBar(ctx: Ctx): SafeHtml {
  return html`<header class="entrance-bar">
    <a class="mark" href="/"><img src="${config.siteLogo}" alt="" width="64" height="64" />${config.siteName}</a>
    ${langPicker(ctx)}
  </header>`;
}

// ── 法的ページへの静かな入り口(gateway が焼いた一枚へ。Unpoly は通さない)──
export function legalFooter(ctx: Ctx): SafeHtml {
  const lang = ctx.locale === 'ko' ? '?lang=ko' : '';
  return html`<footer class="legal-foot">
    <a href="/terms${lang}" up-follow="false">${ctx.t('signup.termsLink')}</a>
    <span class="sep" aria-hidden="true">·</span>
    <a href="/privacy${lang}" up-follow="false">${ctx.t('signup.privacyLink')}</a>
  </footer>`;
}

// ── ことばを選ぶ窓 ───────────────────────────────────────────────
// cookie に置くので、サーバへ POST する(ふつうのフォーム。置き換えはフルリロード:
// ナビも本文も、ことばが変わるため)。名前は、その言語自身の文字で。
export function langPicker(ctx: Ctx): SafeHtml {
  const next = ctx.url.pathname + ctx.url.search;
  return html`<details class="lang-picker end" x-data @click.outside="$el.open = false" @keydown.escape="$el.open = false">
    <summary aria-label="${ctx.t('lang.switch')}: ${LOCALE_NAMES[ctx.locale]}">
      <svg aria-hidden="true" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9" /><path d="M3 12h18" /><path d="M12 3c2.6 2.7 3.9 5.7 3.9 9s-1.3 6.3-3.9 9c-2.6-2.7-3.9-5.7-3.9-9S9.4 5.7 12 3z" /></svg>
      <span lang="${ctx.locale}">${LOCALE_NAMES[ctx.locale]}</span>
      <svg class="chev" aria-hidden="true" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6" /></svg>
    </summary>
    <form method="post" action="/lang">
      <input type="hidden" name="next" value="${next}" />
      <ul>
        ${LOCALES.map(
          (l: Locale) => html`<li><button type="submit" name="l" value="${l}" class="opt" lang="${l}" aria-current="${ctx.locale === l ? 'true' : null}">
            <span class="check" aria-hidden="true">${ctx.locale === l ? raw('<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M6 12.5l4 4 8-9" /></svg>') : ''}</span>
            ${LOCALE_NAMES[l]}
          </button></li>`
        )}
      </ul>
    </form>
  </details>`;
}

// ── Unpoly の置き換え先 ─────────────────────────────────────────
// up.form.config.submitSelectors により、フォームは自動で <main> を差し替える。
// 互換性のため残しているが、各フォームでの指定は不要。
export const UP_MAIN = raw('');
