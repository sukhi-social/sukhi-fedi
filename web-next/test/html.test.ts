// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { html, raw } from '../server/html.ts';

test('差し込んだ値は、エスケープされる', () => {
  const evil = `<img src=x onerror="alert(1)">'`;
  assert.equal(String(html`<p>${evil}</p>`), '<p>&lt;img src=x onerror=&quot;alert(1)&quot;&gt;&#39;</p>');
});

test('raw だけが、そのまま通る。入れ子の html も', () => {
  assert.equal(String(html`<div>${raw('<b>ok</b>')}${html`<i>${'<'}</i>`}</div>`), '<div><b>ok</b><i>&lt;</i></div>');
});

test('配列は連ねる。null / false / true は、何も出さない', () => {
  assert.equal(String(html`${['<a>', raw('<b>')]}${null}${false}${true}${undefined}`), '&lt;a&gt;<b>');
});
