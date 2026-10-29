// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { detectLocale } from '../server/i18n.ts';

test('端末で選んだものが先', () => {
  assert.equal(detectLocale('ko', 'ja', 'ja'), 'ko');
});

test('アカウントの言語を、ブラウザより先に使う', () => {
  assert.equal(detectLocale(undefined, 'ko', 'ja-JP,ja;q=0.9'), 'ko');
  assert.equal(detectLocale(undefined, 'ko_KR', 'ja'), 'ko');
});

test('アカウントが null のときは、ブラウザの言語で決める', () => {
  assert.equal(detectLocale(undefined, null, 'ko-KR,ko;q=0.9,en;q=0.8'), 'ko');
  assert.equal(detectLocale(undefined, undefined, 'ja'), 'ja');
});

test('ブラウザは並びの最初に合うもの。en のあとの ko も拾う', () => {
  assert.equal(detectLocale(undefined, null, 'en-US,en;q=0.9,ko;q=0.8'), 'ko');
});

test('持っていない言語だけなら ja', () => {
  assert.equal(detectLocale(undefined, 'en', 'fr,de'), 'ja');
  assert.equal(detectLocale(undefined, null, undefined), 'ja');
});
