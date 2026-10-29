// ちいさな i18n。辞書は sukhi-web-next の ja/ko をそのまま借り(locales/ja.ts, ko.ts)、
// この再実装で足したことばだけを locales/extra.ts に置く。
//
// ブラウザの localStorage は、サーバから見えない。選んだことばは cookie(sukhi_locale)に
// 置き、無ければ Accept-Language、それも無ければ日本語。

import { ja } from './locales/ja.ts';
import { ko } from './locales/ko.ts';
import { jaExtra, koExtra } from './locales/extra.ts';

export type Locale = 'ja' | 'ko';
export const LOCALES: Locale[] = ['ja', 'ko'];

// 言語の名前は、その言語自身の文字で出す(切替の窓用)。
export const LOCALE_NAMES: Record<Locale, string> = { ja: '日本語', ko: '한국어' };

const dicts: Record<Locale, Record<string, string>> = {
  ja: { ...ja, ...jaExtra },
  ko: { ...ko, ...koExtra }
};

export type TranslationKey = keyof typeof ja | keyof typeof jaExtra;
export type T = (key: TranslationKey, params?: Record<string, string | number>) => string;

export function isLocale(v: unknown): v is Locale {
  return v === 'ja' || v === 'ko';
}

// ja-JP / ko_KR のような印も、先頭の二字で読む。ja・ko 以外(en など)は、持っていないので無し。
function toLocale(v: string | null | undefined): Locale | null {
  const l = (v ?? '').toLowerCase().slice(0, 2);
  return isLocale(l) ? l : null;
}

// 決め方: ① この端末で選んだもの(cookie) ② sukhi のアカウントの言語(source.language)
// ③ ブラウザの言語(Accept-Language の並びの、最初に合うもの) ④ ja。
// ②が null(まだ決めていない)なら、③で決める。
export function detectLocale(
  cookie: string | undefined,
  accountLanguage: string | null | undefined,
  acceptLanguage: string | undefined
): Locale {
  if (isLocale(cookie)) return cookie;
  const own = toLocale(accountLanguage);
  if (own) return own;
  for (const part of (acceptLanguage ?? '').split(',')) {
    const found = toLocale(part.split(';')[0].trim());
    if (found) return found;
  }
  return 'ja';
}

export function makeT(locale: Locale): T {
  return (key, params) => {
    let s = dicts[locale][key] ?? dicts.ja[key] ?? key;
    if (params) for (const k in params) s = s.replaceAll(`{${k}}`, String(params[k]));
    return s;
  };
}
