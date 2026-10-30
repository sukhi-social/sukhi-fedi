// SPDX-License-Identifier: AGPL-3.0-or-later
// フォロワー・フォロー中の一覧。'/@:acct/:id'(投稿の詳細)に飲まれず、名前の並びが出る。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

test('/@name/followers と /@name/following は、一覧の頁になる(投稿の 404 にならない)', async () => {
  const port = 5198;
  const base = `http://localhost:${port}`;
  const child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: '', QUIET: '1', PORT: String(port), MOCK_PORT: String(port - 1000), PUBLIC_ORIGIN: base },
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
    for (const kind of ['followers', 'following']) {
      const res = await fetch(`${base}/@aya/${kind}`);
      assert.equal(res.status, 200, kind);
      const page = await res.text();
      assert.match(page, /class="account-row"/, kind);
    }
    // プロフィールから、二つの一覧へ行ける。
    const profile = await (await fetch(`${base}/@aya`)).text();
    assert.match(profile, /href="\/@[^"]+\/followers"/);
    assert.match(profile, /href="\/@[^"]+\/following"/);
  } finally {
    child.kill();
  }
});
