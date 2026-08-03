// 絵文字の付け外しの試験。
//
//   node --test src/lib/reactions.test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { toggled, willAdd } from './reactions.ts';

test('誰も付けていない絵文字は、自分が最初になる', () => {
  assert.equal(willAdd([], '👍'), true);
  assert.deepEqual(toggled([], '👍'), [{ name: '👍', count: 1, me: true }]);
});

test('ほかの人が付けているところに乗る', () => {
  const list = [{ name: '👍', count: 2, me: false }];
  assert.equal(willAdd(list, '👍'), true);
  assert.deepEqual(toggled(list, '👍'), [{ name: '👍', count: 3, me: true }]);
});

test('自分が付けていたのを外すと、数が減る', () => {
  const list = [{ name: '👍', count: 3, me: true }];
  assert.equal(willAdd(list, '👍'), false);
  assert.deepEqual(toggled(list, '👍'), [{ name: '👍', count: 2, me: false }]);
});

test('自分ひとりだった絵文字は、外すと消える', () => {
  assert.deepEqual(toggled([{ name: '🙏', count: 1, me: true }], '🙏'), []);
});

test('ほかの絵文字には、さわらない', () => {
  const list = [
    { name: '👍', count: 1, me: true },
    { name: '🎉', count: 5, me: false }
  ];
  assert.deepEqual(toggled(list, '👍'), [{ name: '🎉', count: 5, me: false }]);
});

test('並びの順は変えない ── 押すたびに場所が動くと、目で追えない', () => {
  const list = [
    { name: 'あ', count: 1, me: false },
    { name: 'い', count: 1, me: false },
    { name: 'う', count: 1, me: false }
  ];
  assert.deepEqual(
    toggled(list, 'い').map((r) => r.name),
    ['あ', 'い', 'う']
  );
});

test('もとの並びは書き換えない', () => {
  const list = [{ name: '👍', count: 1, me: true }];
  toggled(list, '👍');
  assert.deepEqual(list, [{ name: '👍', count: 1, me: true }]);
});
