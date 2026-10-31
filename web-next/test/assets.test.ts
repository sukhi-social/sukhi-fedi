// SPDX-License-Identifier: AGPL-3.0-or-later
// 頁が読む CSS・JS の URL に、中身の版(?v=)が付く。デプロイのあと、ブラウザが古い版を使い続けないため。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { assetUrl } from '../server/assets.ts';

test('assetUrl: 中身の指紋が付く。同じ中身なら同じ、変わると変わる', () => {
  const dir = new URL('../data/brand/', import.meta.url);
  const file = new URL('assets-test.css', dir);
  mkdirSync(dir, { recursive: true });
  try {
    writeFileSync(file, 'a { color: red }');
    const first = assetUrl('/brand/assets-test.css');
    assert.match(first, /^\/brand\/assets-test\.css\?v=[0-9a-f]{10}$/);
    assert.equal(assetUrl('/brand/assets-test.css'), first);

    writeFileSync(file, 'a { color: blue }');
    assert.notEqual(assetUrl('/brand/assets-test.css'), first);
  } finally {
    rmSync(file, { force: true });
  }
});

test('assetUrl: 見つからないもの・置き場の外へ出るものは、そのまま返す', () => {
  assert.equal(assetUrl('/assets/css/no-such-file.css'), '/assets/css/no-such-file.css');
  assert.equal(assetUrl('/assets/../server/config.ts'), '/assets/../server/config.ts');
  assert.equal(assetUrl('/not-mounted/x.css'), '/not-mounted/x.css');
});

test('頁の <head> は版つきの URL を読み、?v= が付いていても配られる', async () => {
  const port = 5197;
  const base = `http://localhost:${port}`;
  const child = spawn('node', ['mock/dev.mjs'], {
    env: {
      ...process.env,
      SUKHI_DEV_TOKEN: '',
      QUIET: '1',
      PORT: String(port),
      MOCK_PORT: String(port - 1000),
      PUBLIC_ORIGIN: base
    },
    stdio: 'ignore'
  });
  try {
    for (let i = 0; i < 50; i++) {
      try {
        if ((await fetch(`${base}/login`)).ok) break;
      } catch {
        // まだ立っていない。
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    const page = await (await fetch(`${base}/login`)).text();
    const urls = [...page.matchAll(/(?:href|src)="(\/assets\/[^"]+)"/g)].map((m) => m[1]);
    assert.ok(urls.length >= 7, `読み込みが 7 本以上: ${urls.join(' ')}`);
    for (const u of urls) {
      assert.match(u, /\?v=[0-9a-f]{10}$/, `${u} に版が付く`);
      assert.equal((await fetch(`${base}${u}`)).status, 200, `${u} が配られる`);
    }
  } finally {
    child.kill();
  }
});
