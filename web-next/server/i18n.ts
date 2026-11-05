// SPDX-License-Identifier: AGPL-3.0-or-later
// ちいさな i18n。辞書は sukhi-web-next の ja/ko をそのまま借り(locales/ja.ts, ko.ts)、
// この再実装で足したことばだけを locales/extra.ts に置く。
//
// ブラウザの localStorage は、サーバから見えない。選んだことばは cookie(sukhi_locale)に
// 置き、無ければ Accept-Language、それも無ければ日本語。

import { ja } from './locales/ja.ts';
import { ko } from './locales/ko.ts';
import { en } from './locales/en.ts';
import { jaExtra, koExtra, enExtra } from './locales/extra.ts';
import { jaTranslate, koTranslate, enTranslate } from './locales/translate.ts';
import { jaMaintenance, koMaintenance, enMaintenance } from './locales/maintenance.ts';

export type Locale = 'ja' | 'ko' | 'en';
export const LOCALES: Locale[] = ['ja', 'ko', 'en'];

// 言語の名前は、その言語自身の文字で出す(切替の窓用)。
export const LOCALE_NAMES: Record<Locale, string> = { ja: '日本語', ko: '한국어', en: 'English' };

const dicts: Record<Locale, Record<string, string>> = {
  ja: { ...ja, ...jaExtra, ...jaTranslate, ...jaMaintenance },
  ko: { ...ko, ...koExtra, ...koTranslate, ...koMaintenance },
  en: { ...en, ...enExtra, ...enTranslate, ...enMaintenance }
};

export type TranslationKey = keyof typeof ja | keyof typeof jaExtra | keyof typeof jaTranslate | keyof typeof jaMaintenance;
export type T = (key: TranslationKey, params?: Record<string, string | number>) => string;

export function isLocale(v: unknown): v is Locale {
  return v === 'ja' || v === 'ko' || v === 'en';
}

// ja-JP / ko_KR / en-GB のような印も、先頭の二字で読む。持っていない言語(fr など)は無し。
function toLocale(v: string | null | undefined): Locale | null {
  const l = (v ?? '').toLowerCase().slice(0, 2);
  return isLocale(l) ? l : null;
}

// 決め方: ① この端末で選んだもの(cookie) ② sukhi のアカウントの言語(source.language)
// ③ ブラウザの言語(Accept-Language の並びの、最初に合うもの)
// ④ どれにも合わなければ: ことばの印が何か付いていれば en(持っていない言語の人には、
//    日本語より英語のほうが読める)。印がまったく無ければ ja(この郵便局の、もとのことば)。
// ②が null(まだ決めていない)なら、③で決める。
export function detectLocale(
  cookie: string | undefined,
  accountLanguage: string | null | undefined,
  acceptLanguage: string | undefined
): Locale {
  if (isLocale(cookie)) return cookie;
  const own = toLocale(accountLanguage);
  if (own) return own;
  let asked = false;
  for (const part of (acceptLanguage ?? '').split(',')) {
    const tag = part.split(';')[0].trim();
    if (!tag || tag === '*') continue;
    asked = true;
    const found = toLocale(tag);
    if (found) return found;
  }
  return asked ? 'en' : 'ja';
}

export function makeT(locale: Locale): T {
  return (key, params) => {
    let s = dicts[locale][key] ?? dicts.ja[key] ?? key;
    if (params) for (const k in params) s = s.replaceAll(`{${k}}`, String(params[k]));
    return s;
  };
}

// 規約・プライバシーの頁は、gateway が ja・ko・en を焼いている(英語は下訳で、食いちがうときは日本語)。
// ja は既定なので `lang=` を足さない。
export function legalLang(locale: Locale): 'ko' | 'en' | null {
  return locale === 'ja' ? null : locale;
}
