// SPDX-License-Identifier: AGPL-3.0-or-later
// 投稿の「訳を見る」。原文は動かさず、その下に訳を足す(docs/TRANSLATION.md)。
//
//   ・押したときだけ。自動では訳さない。
//   ・訳の欄には、いつもエンジン名が出る(DeepL の注意はタイムラインでは言わない ── 設定で一度だけ)。
//   ・学んでいることばの投稿は、訳を閉じて淡く(learn)。ボタンも「訳をひらく」。
//   ・うまくいかないときは、責めずに、理由と、次の一手。原文は、そのまま読める。

import { html, raw, type SafeHtml } from '../html.ts';
import type { Ctx } from '../http.ts';
import type { TranslationKey } from '../i18n.ts';
import { baseLang, guessLang, offerFor, prefsOf, translationEnabled, type Offer } from '../translate.ts';
import type { Account, Status } from '../types.ts';

export type Translation = {
  content: string;
  spoiler_text?: string;
  detected_source_language?: string;
  provider?: string;
};

// gateway の error ことば → 見出しと本文の鍵(settings: 設定への道を添えるか)。
const PROBLEMS: Record<string, { key: string; settings?: boolean }> = {
  busy: { key: 'busy' },
  no_key: { key: 'noKey', settings: true },
  key_rejected: { key: 'keyRejected', settings: true },
  quota: { key: 'quota', settings: true },
  too_long: { key: 'tooLong' },
  unsupported_language: { key: 'unsupported' },
  translation_disabled: { key: 'disabled', settings: true },
  not_translatable: { key: 'direct' },
  engine_unavailable: { key: 'unavailable' }
};

export const problemOf = (code: string) => PROBLEMS[code] ?? { key: 'failed' };

export type Slot = { result?: Translation; problem?: string };

export const slotId = (domId: string) => `tr-${domId}`;

// そのことばの、そのことば自身の文字での名前(日本語 / 한국어 / English)。
export function endonym(code: string): string {
  try {
    return new Intl.DisplayNames([code], { type: 'language' }).of(code) ?? code;
  } catch {
    return code;
  }
}

export function offerOf(s: Status, me: Account | null, ctx: Ctx): { offer: Offer; lang: string | null } {
  const prefs = prefsOf(me, ctx.locale);
  const lang = baseLang(s.language) ?? guessLang(s.content ?? '').lang;
  return { offer: offerFor(s, me, prefs, translationEnabled()), lang };
}

function box(ctx: Ctx, result: Translation, target: string): SafeHtml {
  const t = ctx.t;
  return html`<div class="tr-box" x-show="open" translate="no" lang="${target}">
    <p class="tr-label">
      <span>${t('translate.label')}</span>${result.provider ? html`<span aria-hidden="true">・</span><span>${result.provider}</span>` : ''}
      <button type="button" @click="open = false">${t('translate.close')}</button>
    </p>
    ${result.spoiler_text ? html`<p class="tr-spoiler">${result.spoiler_text}</p>` : ''}
    <div class="tr-body content">${raw(result.content)}</div>
  </div>`;
}

function problem(ctx: Ctx, code: string): SafeHtml {
  const t = ctx.t;
  const p = problemOf(code);
  const title = t(`translate.err.${p.key}.title` as TranslationKey);
  const body = t(`translate.err.${p.key}.body` as TranslationKey);
  return html`<div class="tr-note" role="status" x-data="{ gone: false }" x-show="!gone">
    <h3>${title}</h3>
    <p class="muted">${body}</p>
    <div class="row">
      ${p.settings ? html`<a class="chip" href="/settings/translation">${t('translate.err.toSettings')}</a>` : ''}
      <button type="button" class="chip" @click="gone = true">${t('translate.later')}</button>
    </div>
  </div>`;
}

// 一つの投稿の下に置く、「訳」の場所。ボタン(押せるとき)か、開いた訳か、うまくいかなかった知らせ。
// 何も出さないときは、空(場所そのものも置かない)。
//
// 外側(#tr-…)は up-keep ── お気に入りなどで投稿が差し替わっても、開いた訳は消えない。
// 押したときに差し替わるのは、内側(#tr-…-body)だけ。
export function translateSlot(ctx: Ctx, s: Status, me: Account | null, domId: string, slot?: Slot): SafeHtml {
  const t = ctx.t;
  const { offer, lang } = offerOf(s, me, ctx);
  const asked = !!(slot?.result || slot?.problem);
  if (offer === 'none' && !asked) return html``;

  const prefs = prefsOf(me, ctx.locale);
  const learn = offer === 'learn' || (!!lang && prefs.learns.includes(lang));
  const id = slotId(domId);
  const result = slot?.result;
  const hint = learn && !asked && lang ? html`<span class="tr-learn-hint">${t('translate.learnHint', { lang: endonym(lang) })}</span>` : '';
  const label = learn ? t('translate.open') : t('translate.see');
  return html`<div id="${id}" class="tr-slot ${learn ? 'learn-on' : ''}" up-keep>
    <div id="${id}-body" x-data="{ open: ${String(!!result)} }">
      ${result
        ? html`<p class="tr-hint" x-show="!open" x-cloak><button type="button" class="chip tr-btn" @click="open = true">${label}</button></p>`
        : html`<form method="post" action="/statuses/${s.id}/translate" in-place up-target="#${id}-body" up-disable class="tr-hint">
            <input type="hidden" name="dom" value="${domId}" />
            <button type="submit" class="chip tr-btn">${label}</button>${hint}
          </form>`}
      ${result ? box(ctx, result, prefs.target) : ''}
      ${slot?.problem ? problem(ctx, slot.problem) : ''}
    </div>
  </div>`;
}
