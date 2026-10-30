// SPDX-License-Identifier: AGPL-3.0-or-later
// 「入っている端末」に出す、端末のことばと場所。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deviceLabel, placeLabel } from '../server/device.ts';
import { clientHeaders } from '../server/gateway.ts';

test('deviceLabel: ブラウザと OS を読む。"node" や空は端末の名前にしない', () => {
  assert.equal(
    deviceLabel('Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0'),
    'Firefox · Windows'
  );
  assert.equal(
    deviceLabel('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'),
    'Safari · iOS'
  );
  assert.equal(
    deviceLabel('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36 Edg/128.0'),
    'Edge · Windows'
  );
  assert.equal(deviceLabel('node'), null);
  assert.equal(deviceLabel(''), null);
  assert.equal(deviceLabel(null), null);
});

test('placeLabel: 内側のアドレスは場所として出さない', () => {
  assert.equal(placeLabel('172.21.0.x'), null);
  assert.equal(placeLabel('10.0.0.x'), null);
  assert.equal(placeLabel('fd12:…'), null);
  assert.equal(placeLabel('?'), null);
  assert.equal(placeLabel('203.0.113.x'), '203.0.113.x');
  assert.equal(placeLabel('2a02:…'), '2a02:…');
});

test('clientHeaders: 利用者の User-Agent も gateway に伝える', () => {
  const ctx = { req: { headers: { 'cf-connecting-ip': '198.51.100.7', 'user-agent': 'Mozilla/5.0 Firefox/130.0' } } } as never;
  assert.deepEqual(clientHeaders(ctx), { 'cf-connecting-ip': '198.51.100.7', 'user-agent': 'Mozilla/5.0 Firefox/130.0' });
});
