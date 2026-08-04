// live の管から来た一枠を、正しく読み分けられるか。
//
//   node --test src/lib/direct.test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { isThisConversation } from './direct.ts';

// サーバが実際に送る形。payload は**それ自体が JSON の文字列**
// (Mastodon の二重包み)。ここを素の object と思い込むと、id が読めない
// まま黙って false になり、管が生きているのに何も起きない。
const frame = (id: string) =>
  JSON.stringify({
    stream: ['direct'],
    event: 'conversation',
    payload: JSON.stringify({ id, unread: true, accounts: [], last_status: { id: '9' } })
  });

test('この会話の枠なら、合図', () => {
  assert.equal(isThisConversation(frame('5726'), '5726'), true);
});

test('よその会話の枠は、合図ではない', () => {
  // 会話ごとに管を開くのではなく、一本で全部の DM が流れてくる。
  // ここで分けないと、別の人との会話が動くたびにこの画面が API を叩く。
  assert.equal(isThisConversation(frame('9999'), '5726'), false);
});

test('id は文字と数のどちらで来ても、同じものとして扱う', () => {
  const numeric = JSON.stringify({
    event: 'conversation',
    payload: JSON.stringify({ id: 5726 })
  });
  assert.equal(isThisConversation(numeric, '5726'), true);
});

test('包まれていない payload でも読める', () => {
  // 二重包みは Mastodon の作法だけれど、そうでない実装もありうる。
  const plain = JSON.stringify({ event: 'conversation', payload: { id: '5726' } });
  assert.equal(isThisConversation(plain, '5726'), true);
});

test('conversation 以外の出来事は、無視する', () => {
  const update = JSON.stringify({
    event: 'update',
    payload: JSON.stringify({ id: '5726' })
  });
  assert.equal(isThisConversation(update, '5726'), false);
});

test('ハートビートや、読めない形では動かない', () => {
  // 分からないものを合図と見なして API を叩き続けるより、静かにしている
  // ほうがいい。60 秒の見直しが最後の砦として残っている。
  for (const junk of ['', ':thump', '{壊れた', '{}', 'null', 42, null, undefined, {}]) {
    assert.equal(isThisConversation(junk, '5726'), false, `${String(junk)} で動いてしまった`);
  }
});

test('id の無い payload は、合図ではない', () => {
  const noId = JSON.stringify({ event: 'conversation', payload: JSON.stringify({ unread: true }) });
  assert.equal(isThisConversation(noId, '5726'), false);
});
