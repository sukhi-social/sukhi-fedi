// SPDX-License-Identifier: AGPL-3.0-or-later
// サイトの名前とロゴ(SITE_NAME / SITE_LOGO)。ナビ・入口の帯・<title> に出る。
// ロゴは、data/brand/ に置けば /brand/ で配られる(image を焼きなおさず替えるため)。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';

async function withServer(
  port: number,
  env: Record<string, string>,
  body: (base: string) => Promise<void>
): Promise<void> {
  const base = `http://localhost:${port}`;
  const child = spawn('node', ['mock/dev.mjs'], {
    env: {
      ...process.env,
      SUKHI_DEV_TOKEN: '',
      QUIET: '1',
      PORT: String(port),
      MOCK_PORT: String(port - 1000),
      PUBLIC_ORIGIN: base,
      ...env
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
    await body(base);
  } finally {
    child.kill();
  }
}

test('SITE_NAME と SITE_LOGO が、入口の帯と <title> に出る。ロゴは /brand/ から配れる', async () => {
  const dir = new URL('../data/brand/', import.meta.url);
  mkdirSync(dir, { recursive: true });
  writeFileSync(new URL('logo-test.png', dir), 'not really a png');
  try {
    await withServer(5196, { SITE_NAME: 'テスト星', SITE_LOGO: '/brand/logo-test.png' }, async (base) => {
      const page = await (await fetch(`${base}/login`)).text();
      assert.match(page, /<title>[^<]*· テスト星<\/title>/);
      assert.match(page, /<img src="\/brand\/logo-test\.png"[^>]*\/>テスト星/);
      assert.doesNotMatch(page, />sukhi-fedi</);
      // タブのアイコンも同じ絵になる。
      assert.match(page, /<link rel="icon" href="\/brand\/logo-test\.png" \/>/);

      const logo = await fetch(`${base}/brand/logo-test.png`);
      assert.equal(logo.status, 200);
      assert.equal(await logo.text(), 'not really a png');

      // data/ のほかのものは配らない。
      assert.equal((await fetch(`${base}/brand/../sessions.json`)).status, 404);
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('SITE_LOGO が .svg なら、タブのアイコンに type が付く(引用符が escape されない)', async () => {
  await withServer(5197, { SITE_LOGO: 'https://example.test/logo.svg' }, async (base) => {
    const page = await (await fetch(`${base}/login`)).text();
    assert.match(page, /<link rel="icon" type="image\/svg\+xml" href="https:\/\/example\.test\/logo\.svg" \/>/);
  });
});

test('何も書かなければ sukhi-fedi と /favicon.png。ロゴの指定が変なら、既定に戻る', async () => {
  await withServer(5195, { SITE_LOGO: 'javascript:alert(1)' }, async (base) => {
    const page = await (await fetch(`${base}/login`)).text();
    assert.match(page, /<img src="\/favicon\.png"[^>]*\/>sukhi-fedi/);
    assert.match(page, /<title>[^<]*· sukhi-fedi<\/title>/);
    assert.match(page, /<link rel="icon" href="\/favicon\.png" \/>/);
    assert.doesNotMatch(page, /javascript:/);
  });
});
