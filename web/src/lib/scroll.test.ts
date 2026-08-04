// 会話の面のスクロールの決めごとの試験。
//
//   node --test src/lib/scroll.test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  BOTTOM_SLACK_PX,
  atBottom,
  distanceFromBottom,
  keepPlaceAfterPrepend,
  onArrival
} from './scroll.ts';

// 画面 800、中身 5000 の会話で考える。
const VIEW = 800;
const DOC = 5000;
const BOTTOM = DOC - VIEW; // 4200

test('底にいれば、底', () => {
  assert.equal(atBottom(BOTTOM, VIEW, DOC), true);
});

test('あと少しで底なら、底とみなす', () => {
  // 指を離したあとの慣性や、アドレスバーの伸び縮みで数 px ずれる。
  // そこで「下にいない」ことにすると、ついていってほしい人が置き去りになる。
  assert.equal(atBottom(BOTTOM - 10, VIEW, DOC), true);
  assert.equal(atBottom(BOTTOM - BOTTOM_SLACK_PX, VIEW, DOC), true);
});

test('余裕を越えて遡っていたら、底ではない', () => {
  assert.equal(atBottom(BOTTOM - BOTTOM_SLACK_PX - 1, VIEW, DOC), false);
  assert.equal(atBottom(0, VIEW, DOC), false);
});

test('中身が画面より短ければ、いつでも底', () => {
  assert.equal(atBottom(0, 800, 500), true);
});

// ── 新しい一通が来たとき ────────────────────────────────────────────

test('下にいたら、ついていく', () => {
  assert.equal(onArrival({ added: 1, wasAtBottom: true }), 'follow');
});

test('**遡っていたら、動かさない。**知らせるだけ', () => {
  // ここがこの規則の芯。読んでいる最中に足元をさらわれるのは、
  // 新しい一通を見逃すことより困る。
  assert.equal(onArrival({ added: 1, wasAtBottom: false }), 'mark');
});

test('自分が送ったぶんは、遡っていてもついていく', () => {
  // 送信は「いま、ここに居る」の一番はっきりした合図。自分の言葉が
  // 画面の外に出るのは、ただ壊れて見える。
  assert.equal(onArrival({ added: 1, wasAtBottom: false, mine: true }), 'follow');
});

test('増えていなければ、何もしない', () => {
  // 拾い直しは空振りが普通。空振りのたびに動いたら、それは痙攣。
  assert.equal(onArrival({ added: 0, wasAtBottom: false }), 'nothing');
  assert.equal(onArrival({ added: 0, wasAtBottom: true }), 'nothing');
  assert.equal(onArrival({ added: 0, wasAtBottom: true, mine: true }), 'nothing');
});

// ── 古いぶんを上に足したとき ────────────────────────────────────────

test('上に足しても、読んでいた場所にいられる', () => {
  // 実測で 4348px ぶん足されて、y が 0 のまま置いていかれた形。
  const before = distanceFromBottom(4200, 5000); // 800
  const after = keepPlaceAfterPrepend(before, 9348);
  assert.equal(after, 8548);
  // 下からの距離が変わっていない = 同じ一通を見ている。
  assert.equal(distanceFromBottom(after, 9348), before);
});

test('いちばん上で押しても、同じ一通のところに戻る', () => {
  // 「もっと読む」は上にあるので、押すときは必ずここに居る。
  // ブラウザの位置保持はこの場所では効かないから、ここが本番。
  const before = distanceFromBottom(0, 5000); // 5000
  const after = keepPlaceAfterPrepend(before, 9348);
  assert.equal(after, 4348);
  assert.equal(distanceFromBottom(after, 9348), 5000);
});

test('縮んだときは、負にならない', () => {
  // 消したり畳んだりで中身が短くなることはある。負の座標は無い。
  assert.equal(keepPlaceAfterPrepend(9000, 5000), 0);
});
