// ちいさな i18n。依存を足さず、ストアひとつと t() ひとつだけ。
//
//   {$t('common.loading')}                テンプレートで
//   {$t('timeline.emptyTag', { tag })}    差し込みつきで
//
// locale が変わると derived の t が作り直されるので、$t を参照して
// いるところは静かに描き直される。ja を正本に、ko に無い鍵があっても
// ja へ落ちる(型で防いではいるけれど、念のため)。
import { writable, derived } from 'svelte/store';
import { browser } from '$app/env';
import { ja, type TranslationKey } from './locales/ja';
import { ko } from './locales/ko';

export type { TranslationKey } from './locales/ja';

export type Locale = 'ja' | 'ko';
export const LOCALES: Locale[] = ['ja', 'ko'];

// 言語の名前は、その言語自身の文字で出す(切替ボタン用)。
export const LOCALE_NAMES: Record<Locale, string> = {
  ja: '日本語',
  ko: '한국어'
};

const dicts: Record<Locale, Record<TranslationKey, string>> = { ja, ko };

const STORAGE_KEY = 'sukhi.locale';

// 初回は localStorage の記憶 → ブラウザ言語 → 日本語、の順で決める。
function detect(): Locale {
  if (!browser) return 'ja';
  const saved = localStorage.getItem(STORAGE_KEY);
  if (saved === 'ja' || saved === 'ko') return saved;
  const nav = (navigator.language || '').toLowerCase();
  return nav.startsWith('ko') ? 'ko' : 'ja';
}

export const locale = writable<Locale>(detect());

// locale が決まる / 変わるたびに <html lang> を合わせる。読み上げや
// 折り返し(word-break: keep-all は ja/ko どちらも自然)に効く。
if (browser) {
  locale.subscribe((l) => {
    document.documentElement.lang = l;
  });
}

export function setLocale(l: Locale): void {
  if (browser) localStorage.setItem(STORAGE_KEY, l);
  locale.set(l);
}

function translate(
  l: Locale,
  key: TranslationKey,
  params?: Record<string, string | number>
): string {
  let s = dicts[l][key] ?? ja[key] ?? key;
  if (params) {
    for (const k in params) s = s.replaceAll(`{${k}}`, String(params[k]));
  }
  return s;
}

export const t = derived(
  locale,
  ($locale) =>
    (key: TranslationKey, params?: Record<string, string | number>): string =>
      translate($locale, key, params)
);
