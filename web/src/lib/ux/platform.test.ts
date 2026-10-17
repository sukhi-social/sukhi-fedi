// どの OS か、の粗いヒントの試験。
//
//   node --test src/lib/ux/platform.test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { detectPlatform, isPrimaryMod, shortcutOf, usesCommandKey } from './platform.ts';

// 実機の userAgent に近い綴り。
const UA = {
  mac: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
  windows: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36',
  // Android の userAgent は "Linux" も名乗る
  android: 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36',
  iphone: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
  linux: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
};

test('userAgent だけでも、五つに分かれる', () => {
  assert.equal(detectPlatform({ userAgent: UA.mac }), 'mac');
  assert.equal(detectPlatform({ userAgent: UA.windows }), 'windows');
  assert.equal(detectPlatform({ userAgent: UA.android }), 'android');
  assert.equal(detectPlatform({ userAgent: UA.iphone }), 'ios');
  assert.equal(detectPlatform({ userAgent: UA.linux }), 'other');
});

test('Android は "Linux" を名乗っても Android', () => {
  assert.equal(detectPlatform({ userAgent: UA.android, uaDataPlatform: 'Android' }), 'android');
});

test('userAgentData があれば、それを先に信じる', () => {
  assert.equal(detectPlatform({ uaDataPlatform: 'macOS' }), 'mac');
  assert.equal(detectPlatform({ uaDataPlatform: 'Windows' }), 'windows');
  assert.equal(detectPlatform({ uaDataPlatform: 'Android' }), 'android');
  assert.equal(detectPlatform({ uaDataPlatform: 'Linux' }), 'other');
});

test('デスクトップ表示の iPad は Mac を名乗るが、タッチがあれば ios', () => {
  assert.equal(detectPlatform({ userAgent: UA.mac, maxTouchPoints: 5 }), 'ios');
  assert.equal(detectPlatform({ userAgent: UA.mac, maxTouchPoints: 0 }), 'mac');
  assert.equal(detectPlatform({ uaDataPlatform: 'macOS', maxTouchPoints: 5 }), 'ios');
});

test('何も分からなければ other', () => {
  assert.equal(detectPlatform({}), 'other');
});

test('⌘ を使うのは Apple の機器だけ', () => {
  assert.equal(usesCommandKey('mac'), true);
  assert.equal(usesCommandKey('ios'), true);
  assert.equal(usesCommandKey('windows'), false);
  assert.equal(usesCommandKey('android'), false);
  assert.equal(usesCommandKey('other'), false);
});

test('主の修飾: Apple は ⌘ だけ、ほかは Ctrl だけ', () => {
  const key = (metaKey: boolean, ctrlKey: boolean) => ({ metaKey, ctrlKey });
  assert.equal(isPrimaryMod(key(true, false), 'mac'), true);
  assert.equal(isPrimaryMod(key(false, true), 'mac'), false); // Control は修飾に使わない
  assert.equal(isPrimaryMod(key(true, true), 'mac'), false);
  assert.equal(isPrimaryMod(key(false, true), 'windows'), true);
  assert.equal(isPrimaryMod(key(true, false), 'windows'), false); // Win キー
  assert.equal(isPrimaryMod(key(false, true), 'android'), true); // 物理キーボード
  assert.equal(isPrimaryMod(key(false, false), 'other'), false);
});

test('aria-keyshortcuts の綴り', () => {
  assert.equal(shortcutOf('Enter', 'mac'), 'Meta+Enter');
  assert.equal(shortcutOf('Enter', 'windows'), 'Control+Enter');
});
