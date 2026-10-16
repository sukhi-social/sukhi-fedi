// SPDX-License-Identifier: AGPL-3.0-or-later
//
// BudouX for the Japanese /licenses pages. LegalController bakes Markdown to
// HTML at compile time with no JS, so the phrase breaks are put into the text
// here: each X.ja.md below becomes X.ja.phrased.md, the same text with a
// zero-width space (U+200B) at the points BudouX found. The controller turns
// each into <wbr> when it bakes (Earmark would escape a literal one), and CSS
// `word-break: keep-all` on `.legal:has(wbr)` makes those the only break points.
// Edit the .ja.md, never the .phrased.md, then run:
//   node scripts/phrase_legal.mjs
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// budoux is a dependency of web/ (the same parser web/src/lib/phrase.ts uses)
const require = createRequire(new URL('../web/package.json', import.meta.url));
const parser = require('budoux').loadDefaultJapaneseParser();

const dir = fileURLToPath(new URL('../elixir/priv/legal/', import.meta.url));
const files = [
  'licenses.ja.md',
  'licenses-rust.ja.md',
  'licenses-end.ja.md',
  'licenses-end-oss.ja.md',
  'licenses-end-last.ja.md',
];

const phrase = (s) => (s.trim() ? parser.parse(s).join('\u200B') : s);

// Text only: HTML tags, entities and the (url) of a Markdown link stay as they are.
const keep = /(<[^>]*>|&#?\w+;|\]\([^)]*\)|`[^`]*`)/;
const line = (l) => {
  if (/^(---|```)/.test(l)) return l;
  const m = l.match(/^(#+\s+|[-*]\s+)?(.*)$/);
  return (m[1] ?? '') + m[2].split(keep).map((p, i) => (i % 2 ? p : phrase(p))).join('');
};

for (const f of files) {
  const src = readFileSync(join(dir, f), 'utf8');
  const out = src.split('\n').map(line).join('\n');
  writeFileSync(join(dir, f.replace('.md', '.phrased.md')), out);
}
