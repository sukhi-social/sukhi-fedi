// SPDX-License-Identifier: AGPL-3.0-or-later
// メンテナンスの頁 ── アプリが止まっている間、静的なサーバー(nginx)が返す一枚。
//
// 意図: 止まっている間に来た人が、「壊れた」ではなく「いま整えています」と受け取れること。
//   あわせて、止まる直前の公開投稿を、読むだけで見られること(返信もお気に入りもできない)。
// 読み手の問題(仮説): 「落ちた? 消えた? いつ戻る? 読むだけでもできない?」
//
// 仕組み: このファイルは何も配らない。HTML の文字列を作るだけの純粋な関数で、
//   server/maintenance-cli.ts が呼び、`scripts/sukhi-maintenance` が箱の上の置き場に書く。
//   配るのは nginx で、アプリが止まっていても答えられる(infra/nginx/、docs/OPS_MAINTENANCE_PAGE.ja.md)。
//
// 安全の置き場(一か所): 外から来た文字は、ここで **文字だけ** にして、出すときに必ずエスケープする。
//   gateway が返す本文 HTML は(書くときに sanitize 済みだが)タグを持つ ── この頁には持ちこまない。
//   だから、頁は `<script>` を一つも持たず、リンクも画像も本文からは出さない。
//
// 数と時刻は出さない(KINDNESS.md)。戻る見込みも「半刻ほど」のようにゆるく言う。

import { esc, html, raw, type SafeHtml } from './html.ts';
import { makeT, LOCALES, LOCALE_NAMES, type Locale } from './i18n.ts';
import { delayWords } from './time.ts';

export type Why = 'update' | 'backup' | 'migration' | 'repair';
export const WHYS: readonly Why[] = ['update', 'backup', 'migration', 'repair'];

export function isWhy(v: unknown): v is Why {
  return typeof v === 'string' && (WHYS as readonly string[]).includes(v);
}

// 頁に載せる一件。文字だけ(HTML ではない)。
export type SnapItem = {
  name: string;
  acct: string;
  text: string;
  // 折りたたむとき。'' は「見出しは既定のことば」、文字列はその人が書いた注意書き。null は折りたたまない。
  fold: string | null;
  lang: string | null;
};

export const MAX_ITEMS = 30;
const MAX_CHARS = 400;

// ── 外から来た本文を、文字だけにする ──────────────────────────────

const NAMED: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };

function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (whole, body: string) => {
    if (body[0] === '#') {
      const code = body[1] === 'x' || body[1] === 'X' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      // 0 と制御文字、サロゲート、範囲の外は、そのまま(文字にしない)。
      if (!Number.isInteger(code) || code < 0x20 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return '';
      return String.fromCodePoint(code);
    }
    return NAMED[body.toLowerCase()] ?? whole;
  });
}

/** gateway の本文(HTML)を、段落を残した文字だけにする。出すときは、かならず esc を通す。 */
export function plainText(content: string): string {
  const text = content
    .replace(/<\s*br\s*\/?\s*>/gi, '\n')
    .replace(/<\/\s*(p|div|li|h[1-6]|blockquote|pre)\s*>/gi, '\n\n')
    .replace(/<[^>]*>/g, '');
  return decodeEntities(text)
    .replace(/\r/g, '')
    .split('\n')
    .map((l) => l.trim())
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function clip(s: string): string {
  const chars = [...s];
  return chars.length > MAX_CHARS ? chars.slice(0, MAX_CHARS).join('').trimEnd() + '…' : s;
}

const LANG_TAG = /^[a-z]{2,3}(-[a-z0-9]{2,8})?$/i;

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}
const str = (v: unknown): string => (typeof v === 'string' ? v : '');

/**
 * gateway の公開タイムライン(`/api/v1/timelines/public?local=true`)から、頁に載せる分を選ぶ。
 * 入力は信じない(形が違えば黙って落とす)。載せるのは、
 *   ・公開(visibility が public)の、その人自身の投稿 ── ブースト・返信・引用は外す(前後が欠けると読めないので)
 *   ・本文が文字として残るもの(画像だけの投稿は外す)
 * 数(お気に入り・ブースト)は持ちこまない。
 */
export function pickItems(input: unknown, max = MAX_ITEMS): SnapItem[] {
  if (!Array.isArray(input)) return [];
  const out: SnapItem[] = [];
  for (const s of input) {
    if (out.length >= max) break;
    if (!isObj(s) || !isObj(s.account)) continue;
    if (s.visibility !== 'public') continue;
    if (s.reblog || s.in_reply_to_id || s.quote) continue;

    const text = clip(plainText(str(s.content)));
    if (!text) continue;

    const acct = str(s.account.acct);
    if (!acct) continue;
    // 独自絵文字の :name: は、この頁では絵にならない。名前から外す。
    const name = str(s.account.display_name).replace(/:[A-Za-z0-9_]+:/g, '').replace(/\s+/g, ' ').trim() || str(s.account.username) || acct;

    const spoiler = plainText(str(s.spoiler_text));
    const fold = spoiler ? clip(spoiler) : s.sensitive === true ? '' : null;
    const lang = LANG_TAG.test(str(s.language)) ? str(s.language) : null;

    out.push({ name, acct, text, fold, lang });
  }
  return out;
}

/** `snapshot` が書いた JSON を読みなおす(頁を作る側でも、形を信じない)。 */
export function asItems(input: unknown): SnapItem[] {
  if (!isObj(input) || !Array.isArray(input.items)) return [];
  const out: SnapItem[] = [];
  for (const i of input.items) {
    if (out.length >= MAX_ITEMS) break;
    if (!isObj(i) || typeof i.text !== 'string' || !i.text || typeof i.acct !== 'string' || !i.acct) continue;
    out.push({
      name: str(i.name) || i.acct,
      acct: i.acct,
      text: clip(i.text),
      fold: typeof i.fold === 'string' ? clip(i.fold) : null,
      lang: LANG_TAG.test(str(i.lang)) ? str(i.lang) : null
    });
  }
  return out;
}

// ── 頁 ───────────────────────────────────────────────────────────

export type PageOptions = {
  locale: Locale;
  siteName: string;
  /** 外へのリンク(このサーバーについて)。http(s) だけを通す。空なら出さない。 */
  aboutUrl?: string;
  why?: Why;
  /** 戻るまでの見込み(分)。無ければ「まだ決まっていません」と言う。 */
  aboutMin?: number;
  items?: SnapItem[];
};

const CSS = `
:root{color-scheme:light dark;--bg:#fffaf3;--surface:#fff;--ink:#3d3029;--muted:#7a685b;--line:#f0dfcc;--accent:#a34d16;--wash:rgba(61,48,41,.06)}
@media (prefers-color-scheme:dark){:root{--bg:#1d1814;--surface:#27201b;--ink:#efe4d8;--muted:#b7a594;--line:#3a2f27;--accent:#f0a56e;--wash:rgba(239,228,216,.07)}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:1rem/1.8 system-ui,-apple-system,'Hiragino Sans','Yu Gothic','Noto Sans CJK JP','Apple SD Gothic Neo','Malgun Gothic','Noto Sans CJK KR',sans-serif}
main{max-width:36rem;margin:0 auto;padding:3rem 1rem 4rem}
h1{font-size:1.5rem;line-height:1.4;margin:0 0 1rem;border-left:.3rem solid var(--accent);padding-left:.75rem}
h2{font-size:1.05rem;margin:2.5rem 0 .25rem}
p{margin:.5rem 0}
.muted{color:var(--muted);font-size:.9rem}
.post{background:var(--surface);border:1px solid var(--line);border-radius:.75rem;padding:.75rem 1rem;margin:.75rem 0}
.who{margin:0 0 .25rem;font-size:.9rem}
.who span{color:var(--muted);margin-left:.4em;overflow-wrap:anywhere}
.body p{margin:.4rem 0;overflow-wrap:anywhere}
summary{cursor:pointer;color:var(--accent)}
nav{margin-top:2.5rem;font-size:.9rem}
nav a,.about a{color:var(--accent)}
nav a[aria-current]{color:var(--ink);font-weight:bold;text-decoration:none}
nav a+a::before{content:'·';margin:0 .5em;color:var(--muted);text-decoration:none;display:inline-block}
.about{margin-top:1rem;font-size:.9rem}
`.replace(/\n/g, '');

function paragraphs(text: string): SafeHtml {
  return html`${text.split('\n\n').map((p) => html`<p>${raw(p.split('\n').map(esc).join('<br>'))}</p>`)}`;
}

function post(item: SnapItem, label: string): SafeHtml {
  const lang = item.lang ? raw(` lang="${esc(item.lang)}"`) : '';
  const head = html`<p class="who"><strong>${item.name}</strong><span>@${item.acct}</span></p>`;
  const body = html`<div class="body"${lang}>${paragraphs(item.text)}</div>`;
  if (item.fold === null) return html`<article class="post">${head}${body}</article>`;
  return html`<article class="post">${head}<details><summary${lang}>${item.fold || label}</summary>${body}</details></article>`;
}

function safeHref(url: string | undefined): string | null {
  return url && /^https?:\/\/[^\s"'<>]+$/i.test(url) ? url : null;
}

/** 一言語ぶんの頁を、自己完結の HTML(外のファイルも script も無し)で返す。 */
export function renderMaintenancePage(o: PageOptions): string {
  const t = makeT(o.locale);
  const items = o.items ?? [];
  const about = safeHref(o.aboutUrl);
  const min = o.aboutMin;

  const eta =
    typeof min !== 'number' || !Number.isFinite(min) || min <= 0
      ? t('maint.etaUnknown')
      : min > 90
        ? t('maint.etaLong')
        : t('maint.eta', { when: delayWords(min, o.locale) });

  const langNav = LOCALES.map(
    (l) => html`<a href="?lang=${l}" hreflang="${l}" lang="${l}"${l === o.locale ? raw(' aria-current="true"') : ''}>${LOCALE_NAMES[l]}</a>`
  );

  return `<!doctype html>
${html`<html lang="${o.locale}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${o.siteName} — ${t('maint.title')}</title>
<link rel="icon" href="data:,">
<style>${raw(CSS)}</style>
</head>
<body>
<main>
<h1>${t('maint.title')}</h1>
<p>${t('maint.lead')}</p>
${o.why ? html`<p>${t(`maint.why.${o.why}`)}</p>` : ''}
<p>${t('maint.kept')}</p>
<p>${eta}</p>
<p>${t('maint.back')}</p>
${items.length
  ? html`<section aria-labelledby="read">
<h2 id="read">${t('maint.readHead')}</h2>
<p class="muted">${t('maint.readNote')}</p>
${items.map((i) => post(i, t('maint.cw')))}
</section>`
  : ''}
<nav aria-label="Language">${langNav}</nav>
${about ? html`<p class="about"><a href="${about}">${t('maint.about')}</a></p>` : ''}
</main>
</body>
</html>
`}`;
}
