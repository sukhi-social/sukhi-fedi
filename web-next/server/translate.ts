// SPDX-License-Identifier: AGPL-3.0-or-later
// 投稿の翻訳の、手元の分: 「訳を見る」を出すかどうか(と、学ぶ見せ方かどうか)を決める。
// docs/TRANSLATION.md。
//
// 訳すこと、送ってよいか(限定公開・DM)、上限、鍵 ── 守りは、ぜんぶ gateway の SukhiFedi.Translate の
// 一か所。ここは、ボタンを出すかどうかの見当だけ。外れても、押せば gateway が正しく答える。
//
// ことばの見当(guessLang)は、字の種類だけを見る。かな→ja、ハングル→ko、ほかの文字はその文字の言語。
// 漢字だけは決められない(中国語かもしれない短い日本語かもしれない)ので null ── ボタンは出して、
// 訳し役に見分けてもらう。ラテン文字は en とみなす(フランス語を読む人の en は、見当違いになりうる)。
// 投稿が自分のことばを名乗っているとき(Status.language)は、そちらを先に信じる。

import { gwJson } from './gateway.ts';
import type { Ctx } from './http.ts';
import type { Account, Status } from './types.ts';

// gateway が訳せる行き先(SukhiFedi.Translate.targets/0 と揃える)。
export const TARGETS = ['ja', 'ko', 'en'] as const;
export type Target = (typeof TARGETS)[number];

const isTarget = (v: string): v is Target => (TARGETS as readonly string[]).includes(v);

// ── ことばの見当 ─────────────────────────────────────────────────
const SCRIPTS: [string, RegExp][] = [
  ['kana', /[぀-ヿㇰ-ㇿｦ-ﾟ]/gu],
  ['hangul', /[ᄀ-ᇿ㄰-㆏가-힯]/gu],
  ['han', /[㐀-䶿一-鿿豈-﫿]/gu],
  ['ru', /[Ѐ-ӿ]/gu],
  ['ar', /[؀-ۿ]/gu],
  ['th', /[฀-๿]/gu],
  ['he', /[֐-׿]/gu],
  ['hi', /[ऀ-ॿ]/gu],
  ['el', /[Ͱ-Ͽ]/gu],
  ['en', /[A-Za-zÀ-ɏ]/gu]
];

// 本文のうち、ことばでない部分(タグ・URL・@ と # ・:絵文字:)を除く。
export function plainText(content: string): string {
  return content
    .replace(/<br\s*\/?>/gi, ' ')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/https?:\/\/\S+/g, ' ')
    .replace(/(^|\s)[@#][^\s]+/g, ' ')
    .replace(/:[A-Za-z0-9_+-]+:/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export type Guess = { lang: string | null; letters: number };

export function guessLang(content: string): Guess {
  const text = plainText(content);
  const counts = new Map<string, number>();
  let letters = 0;
  for (const [name, re] of SCRIPTS) {
    const n = text.match(re)?.length ?? 0;
    counts.set(name, n);
    letters += n;
  }
  const kana = counts.get('kana') ?? 0;
  const hangul = counts.get('hangul') ?? 0;
  const han = counts.get('han') ?? 0;
  if (kana > 0 && kana >= hangul) return { lang: 'ja', letters };
  if (hangul > 0) return { lang: 'ko', letters };
  let best: string | null = null;
  let bestN = 0;
  for (const [name, n] of counts) {
    if (name === 'kana' || name === 'hangul' || name === 'han') continue;
    if (n > bestN) {
      best = name;
      bestN = n;
    }
  }
  // 漢字がいちばん多いなら、決められない。
  if (han > 0 && han >= bestN) return { lang: null, letters };
  return { lang: best, letters };
}

// "ja-JP" / "zh_CN" / "KO" → "ja" / "zh" / "ko"。読めなければ null。
export function baseLang(v: string | null | undefined): string | null {
  const m = /^([A-Za-z]{2,3})(?:[-_]|$)/.exec((v ?? '').trim());
  return m ? m[1].toLowerCase() : null;
}

// ── 読む人の設定 ─────────────────────────────────────────────────
export type Prefs = {
  reads: string[];
  learns: string[];
  engine: 'libre' | 'deepl';
  hasKey: boolean;
  keyHint: string | null;
  // 訳の行き先。読めることばの先頭(訳せることば)、無ければ画面のことば。
  target: Target;
};

const list = (v: unknown): string[] =>
  Array.isArray(v) ? v.map((x) => baseLang(String(x))).filter((x): x is string => !!x) : [];

export function prefsOf(me: Account | null, locale: string): Prefs {
  const src = me?.source;
  const own = list(src?.translate_reads);
  // 何も選んでいなければ、画面のことばだけを「読めること」にする。
  const reads = own.length > 0 ? own : [locale];
  const target = reads.find(isTarget) ?? (isTarget(locale) ? locale : 'ja');
  return {
    reads,
    learns: list(src?.translate_learns),
    engine: src?.translate_engine === 'deepl' ? 'deepl' : 'libre',
    hasKey: !!src?.translate_deepl_key_hint,
    keyHint: src?.translate_deepl_key_hint ?? null,
    target
  };
}

// ── ボタンを出すか ───────────────────────────────────────────────
export type Offer = 'none' | 'ask' | 'learn';

export function offerFor(s: Status, me: Account | null, prefs: Prefs, enabled: boolean): Offer {
  if (!me) return 'none';
  if (s.account.id === me.id) return 'none';
  if (s.visibility === 'direct') return 'none';
  // この場所の訳し役が無くても、自分の DeepL のキーがあれば訳せる(公開・未収載の投稿だけ。ほかは押して知らせる)。
  if (!enabled && !(prefs.engine === 'deepl' && prefs.hasKey)) return 'none';
  const g = guessLang(s.content ?? '');
  if (g.letters < 3) return 'none';
  const lang = baseLang(s.language) ?? g.lang;
  if (lang && prefs.reads.includes(lang)) return 'none';
  return lang && prefs.learns.includes(lang) ? 'learn' : 'ask';
}

// ── この場所に訳し役があるか(手元に 60 秒) ────────────────────────
let known: { on: boolean; at: number } | null = null;
let pending: Promise<void> | null = null;
const TTL = 60_000;

// 同期で読める。古ければ、読み直しは warmTranslation に任せる。
export const translationEnabled = (): boolean => known?.on ?? false;

export async function warmTranslation(ctx: Ctx): Promise<void> {
  if (known && Date.now() - known.at < TTL) return;
  pending ??= (async () => {
    try {
      const i = await gwJson<{ configuration?: { translation?: { enabled?: boolean } } }>(ctx, 'GET', '/api/v2/instance', { auth: false });
      known = { on: i.configuration?.translation?.enabled === true, at: Date.now() };
    } catch {
      // 訊けなかったら、前の答えのまま。一度も訊けていなければ「無い」(出しすぎない側に倒す)。
      known = { on: known?.on ?? false, at: Date.now() - TTL + 5_000 };
    } finally {
      pending = null;
    }
  })();
  await pending;
}

// テスト用。
export function forgetTranslation(): void {
  known = null;
  pending = null;
}
