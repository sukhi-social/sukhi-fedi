// 絵文字検索・インデックス・最近使った絵文字の単体テスト。
//
// 実行方法:
//   node --test src/lib/emoji-search.test.ts

import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import {
  searchEmojis,
  setCustomEmojisCache,
  getCustomEmojisCache,
  recordRecentEmoji,
  getRecentEmojis,
  clearRecentEmojis
} from './emoji-search.ts';

// Mock localStorage for Node test environment
const store: Record<string, string> = {};
(globalThis as any).window = {
  localStorage: {
    getItem: (k: string) => store[k] ?? null,
    setItem: (k: string, v: string) => {
      store[k] = v;
    },
    removeItem: (k: string) => {
      delete store[k];
    }
  }
};

beforeEach(() => {
  for (const k of Object.keys(store)) {
    delete store[k];
  }
  setCustomEmojisCache([]);
});

test('カスタム絵文字のキャッシュと取得', () => {
  setCustomEmojisCache([
    { shortcode: 'blobcat', url: 'https://example.com/blobcat.png', aliases: ['neko', 'ねこ'], category: 'blobs' },
    { shortcode: 'party_parrot', url: 'https://example.com/parrot.gif', aliases: ['parrot'], category: 'blobs' }
  ]);

  const cached = getCustomEmojisCache();
  assert.equal(cached.length, 2);
  assert.equal(cached[0].shortcode, 'blobcat');
});

test('短コードでの前方一致検索', () => {
  setCustomEmojisCache([
    { shortcode: 'blobcat', url: 'https://example.com/blobcat.png', aliases: [] },
    { shortcode: 'blobfox', url: 'https://example.com/blobfox.png', aliases: [] },
    { shortcode: 'neko', url: 'https://example.com/neko.png', aliases: [] }
  ]);

  const results = searchEmojis('blob');
  assert.ok(results.length >= 2);
  assert.equal(results[0].shortcode, 'blobcat');
  assert.equal(results[1].shortcode, 'blobfox');
});

test('エイリアス（日本語含む）での検索', () => {
  setCustomEmojisCache([
    { shortcode: 'blobcat', url: 'https://example.com/blobcat.png', aliases: ['ねこ', '猫'] }
  ]);

  const results = searchEmojis('ねこ');
  assert.ok(results.length >= 1);
  assert.equal(results[0].shortcode, 'blobcat');
});

test('標準 Unicode 絵文字の検索', () => {
  const results = searchEmojis('heart');
  assert.ok(results.length >= 1);
  assert.equal(results[0].shortcode, 'heart');
  assert.equal(results[0].unicode, '❤️');
});

test('コロン付きクエリ（:blob）でも正常に検索できる', () => {
  setCustomEmojisCache([
    { shortcode: 'blobcat', url: 'https://example.com/blobcat.png', aliases: [] }
  ]);

  const results = searchEmojis(':blob');
  assert.ok(results.length >= 1);
  assert.equal(results[0].shortcode, 'blobcat');
});

test('最近使った絵文字の優先表示', () => {
  setCustomEmojisCache([
    { shortcode: 'blob_a', url: 'https://example.com/a.png', aliases: [] },
    { shortcode: 'blob_b', url: 'https://example.com/b.png', aliases: [] }
  ]);

  // 通常は blob_a が先
  let results = searchEmojis('blob');
  assert.equal(results[0].shortcode, 'blob_a');

  // blob_b を使ったと記録
  recordRecentEmoji('blob_b');
  assert.deepEqual(getRecentEmojis(), ['blob_b']);

  // 再検索すると blob_b が最優先になる
  results = searchEmojis('blob');
  assert.equal(results[0].shortcode, 'blob_b');
});

test('空クエリ（:のみ入力）時に最近使った絵文字が先頭に出る', () => {
  setCustomEmojisCache([
    { shortcode: 'blobcat', url: 'https://example.com/blobcat.png', aliases: [] }
  ]);

  recordRecentEmoji('blobcat');
  const results = searchEmojis('');
  assert.ok(results.length > 0);
  assert.equal(results[0].shortcode, 'blobcat');
});
