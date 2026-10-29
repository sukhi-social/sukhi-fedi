// Build-time-friendly BudouX line-breaking for Japanese.
//
// We feed plain text in and get back HTML with <wbr> sprinkled at the
// breakpoints the parser found. The browser is then free to break the
// line only at those points — and with `word-break: keep-all` set in
// base.css it won't break anywhere else. This is the same trick
// atfedi-de's <Phrase> component pulls.

import { loadDefaultJapaneseParser } from 'budoux';

const parser = loadDefaultJapaneseParser();

export function phrase(text: string): string {
  if (!text) return '';
  return parser
    .parse(text)
    .map(escapeHtml)
    .join('<wbr />');
}

// The one place that turns untrusted text into HTML-safe text: every
// reserved character becomes an entity, so nothing the user typed can open
// a tag or attribute. `phrase()` runs it per token; the static MFM renderer
// (mfm.ts) runs it once over the whole source before applying formatting,
// so the only `<` left in the working string are the tags it inserts itself.
export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
