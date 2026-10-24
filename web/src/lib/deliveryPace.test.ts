// 配信の時系列を進める速さの試験。
//
//   node --test src/lib/deliveryPace.test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { STEPS, arrived, stepToward, target, type Shown } from './deliveryPace.ts';

// 目標に着くまで動かして、通った道を集める。
function walk(from: Shown, goal: Shown): Shown[] {
  const path = [from];
  let cur = from;
  while (!arrived(cur, goal)) {
    cur = stepToward(cur, goal);
    path.push(cur);
    assert.ok(path.length < 50, '止まらない');
  }
  return path;
}

test('受付から完了へ一度に飛んでも、段を飛ばさず 1 つずつ通る', () => {
  const path = walk({ at: 0, percent: null }, { at: STEPS.indexOf('done'), percent: 100 });
  assert.deepEqual(
    path.map((s) => STEPS[s.at]),
    ['received', 'signing', 'queued', 'sending', 'done']
  );
});

test('配信中に入ったら 0% から、10 刻みで目標まで', () => {
  const path = walk({ at: 2, percent: null }, { at: 3, percent: 30 });
  assert.deepEqual(
    path.map((s) => s.percent),
    [null, 0, 10, 20, 30]
  );
});

test('目標が手前なら戻らない', () => {
  const shown = { at: 3, percent: 60 };
  assert.deepEqual(stepToward(shown, { at: 1, percent: null }), shown);
  assert.deepEqual(stepToward(shown, { at: 3, percent: 20 }), shown);
});

test('サーバの答えを目標に直す', () => {
  assert.equal(target(null), null);
  assert.deepEqual(target({ stage: 'sending', percent: 40 }), { at: 3, percent: 40 });
});
