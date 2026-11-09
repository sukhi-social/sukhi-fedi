// SPDX-License-Identifier: AGPL-3.0-or-later
// The text paths every post on screen goes through: escaping, MFM, emoji,
// BudouX line breaks, and the html`` template tag.

import { bench, describe } from 'vitest';
import { renderEmojis } from '../server/emoji.ts';
import { esc, html, raw } from '../server/html.ts';
import { renderMfm } from '../server/mfm.ts';
import { escapeHtml, phrase } from '../server/phrase.ts';
import { CONTENT_HTML, EMOJIS, JA_TEXT, LONG_MFM, MFM_SOURCE } from './fixtures.ts';

describe('mfm', () => {
  bench('renderMfm: one note', () => {
    renderMfm(MFM_SOURCE, EMOJIS);
  });

  bench('renderMfm: long note', () => {
    renderMfm(LONG_MFM, EMOJIS);
  });
});

describe('emoji', () => {
  bench('renderEmojis: status content', () => {
    renderEmojis(CONTENT_HTML, EMOJIS);
  });

  bench('renderEmojis: no custom emoji', () => {
    renderEmojis(CONTENT_HTML);
  });
});

describe('phrase', () => {
  bench('phrase: Japanese paragraph', () => {
    phrase(JA_TEXT);
  });

  bench('escapeHtml: status content', () => {
    escapeHtml(CONTENT_HTML);
  });
});

describe('html', () => {
  const items = Array.from({ length: 50 }, (_, i) => `<item ${i} & "quoted">`);

  bench('esc: status content', () => {
    esc(CONTENT_HTML);
  });

  bench('html``: list of 50 escaped items', () => {
    String(html`<ul>${items.map((it) => html`<li class="x">${it}${raw('<b>ok</b>')}</li>`)}</ul>`);
  });
});
