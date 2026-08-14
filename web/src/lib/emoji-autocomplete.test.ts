// 絵文字自動補完の文字境界判定と置換ロジックの単体テスト。
//
// 実行方法:
//   node --test src/lib/emoji-autocomplete.test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { applyEmojiPick, emojiFragmentAt } from './emoji-autocomplete.ts';

test('行頭の : を拾う', () => {
  assert.deepEqual(emojiFragmentAt(':blob', 5), { start: 0, end: 5, query: 'blob' });
});

test('空白のあとの : を拾う', () => {
  assert.deepEqual(emojiFragmentAt('hello :blobcat', 14), { start: 6, end: 14, query: 'blobcat' });
});

test('全角空白のあとの : を拾う', () => {
  assert.deepEqual(emojiFragmentAt('こんにちは　:ねこ', 9), { start: 6, end: 9, query: 'ねこ' });
});

test('各種括弧の直後にある : を拾う', () => {
  assert.deepEqual(emojiFragmentAt('(:blob', 6), { start: 1, end: 6, query: 'blob' });
  assert.deepEqual(emojiFragmentAt('（:blob', 6), { start: 1, end: 6, query: 'blob' });
  assert.deepEqual(emojiFragmentAt('「:ねこ', 4), { start: 1, end: 4, query: 'ねこ' });
  assert.deepEqual(emojiFragmentAt('【:cat', 5), { start: 1, end: 5, query: 'cat' });
});

test(': だけでも fragment として拾う (候補を出すかは呼ぶ側の制御)', () => {
  assert.deepEqual(emojiFragmentAt(':', 1), { start: 0, end: 1, query: '' });
  assert.deepEqual(emojiFragmentAt('hello :', 7), { start: 6, end: 7, query: '' });
});

test('リモートドメイン付き・ローカルプレフィックス付き短コードも拾う', () => {
  assert.deepEqual(emojiFragmentAt(':blobcat@misskey.io', 19), {
    start: 0,
    end: 19,
    query: 'blobcat@misskey.io'
  });
  assert.deepEqual(emojiFragmentAt(':blobcat@.', 10), {
    start: 0,
    end: 10,
    query: 'blobcat@.'
  });
});

test('URL や時刻、文中のコロンは拾わない', () => {
  assert.equal(emojiFragmentAt('https://example.com', 6), null);
  assert.equal(emojiFragmentAt('https://example.com', 19), null);
  assert.equal(emojiFragmentAt('12:30', 3), null);
  assert.equal(emojiFragmentAt('12:30', 5), null);
  assert.equal(emojiFragmentAt('key:value', 4), null);
});

test('すでに閉じられた絵文字の直後は拾わない', () => {
  assert.equal(emojiFragmentAt(':blobcat:', 9), null);
  assert.equal(emojiFragmentAt('(:blobcat:)', 10), null);
});

test('空白が入力されたら fragment ではない', () => {
  assert.equal(emojiFragmentAt(':blobcat ', 9), null);
});

test('カーソル位置より後ろは見ない', () => {
  // :blob|cat -> query は blob
  assert.deepEqual(emojiFragmentAt(':blobcat', 5), { start: 0, end: 5, query: 'blob' });
});

test('短コードでの置き換えとカーソル移動 (コロン付きで置換され空白が付く)', () => {
  const f = emojiFragmentAt(':blob', 5);
  assert.ok(f);
  assert.deepEqual(applyEmojiPick(':blob', f, 'blobcat'), {
    text: ':blobcat: ',
    caret: 10
  });
});

test('すでにコロンで囲まれた短コードが渡された場合も二重コロンにならない', () => {
  const f = emojiFragmentAt(':blob', 5);
  assert.ok(f);
  assert.deepEqual(applyEmojiPick(':blob', f, ':blobcat:'), {
    text: ':blobcat: ',
    caret: 10
  });
});

test('Unicode 絵文字での置き換え', () => {
  const f = emojiFragmentAt(':cat', 4);
  assert.ok(f);
  assert.deepEqual(applyEmojiPick(':cat', f, '🐱'), {
    text: '🐱 ',
    caret: 3
  });
});

test('文章の途中で置換しても前後のテキストを壊さない', () => {
  const text = 'こんにちは :blob 今日も元気です';
  const f = emojiFragmentAt(text, 11);
  assert.ok(f);
  assert.deepEqual(applyEmojiPick(text, f, 'blobcat'), {
    text: 'こんにちは :blobcat:  今日も元気です',
    caret: 16
  });
});

test('置換後は fragment ではなくなる (末尾の空白で切れる)', () => {
  const f = emojiFragmentAt(':blob', 5);
  assert.ok(f);
  const picked = applyEmojiPick(':blob', f, 'blobcat');
  assert.equal(emojiFragmentAt(picked.text, picked.caret), null);
});
