// SPDX-License-Identifier: AGPL-3.0-or-later
// 呼び鈴(SSE)を、テストから開く助け。notify.test.ts と rooms-live.test.ts が使う(テストそのものではない)。
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

// 入っていない人の郵便局。dev では、token の無い session にも SUKHI_DEV_TOKEN が付くので、空にして立てる
// (空文字は `??=` で上書きされず、「無い」ものとして扱われる)。env は、足したい環境変数(トップの入口を見るなら ABOUT_URL: '')。
export async function loggedOutServer(port: number, env: Record<string, string> = {}): Promise<{ base: string; stop: () => void }> {
  const base = `http://localhost:${port}`;
  const child = spawn('node', ['mock/dev.mjs'], {
    env: { ...process.env, SUKHI_DEV_TOKEN: '', QUIET: '1', PORT: String(port), MOCK_PORT: String(port - 1000), PUBLIC_ORIGIN: base, ...env },
    stdio: 'ignore'
  });
  for (let i = 0; i < 50; i++) {
    try {
      if ((await fetch(`${base}/login`)).status < 500) return { base, stop: () => child.kill() };
    } catch {
      // まだ立っていない。
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  child.kill();
  throw new Error('web-next (logged out) did not start');
}

// 流れを開く。読んだぶんは text() に溜まる。until は、その字が現れるまで待つ(流れが閉じたら false)。
export async function openBell(url: string, init: RequestInit = {}) {
  const ac = new AbortController();
  const res = await fetch(url, { ...init, signal: ac.signal, headers: { accept: 'text/event-stream', ...init.headers } });
  const reader = res.body!.getReader();
  const dec = new TextDecoder();
  let seen = '';
  const until = async (re: RegExp, ms = 3000): Promise<boolean> => {
    const t0 = Date.now();
    while (!re.test(seen)) {
      const left = ms - (Date.now() - t0);
      let timer: NodeJS.Timeout | undefined;
      const r = await Promise.race([
        reader.read(),
        new Promise<'late'>((resolve) => (timer = setTimeout(() => resolve('late'), Math.max(left, 1))))
      ]);
      clearTimeout(timer);
      if (r === 'late') throw new Error(`待ちきれませんでした ${re}: ${JSON.stringify(seen)}`);
      if (r.done) return false;
      seen += dec.decode(r.value, { stream: true });
    }
    return true;
  };
  return { res, until, text: () => seen, close: () => ac.abort() };
}

// 偽 gateway が数えている、開いたままの流れの数(GET /__mock/streams)。
// 閉じる伝わりかたは、すこし遅れる ── その数になるまで、少し待つ。
export async function streamsBecome(mock: string, key: 'open' | 'talks', n: number): Promise<void> {
  const now = async () => ((await (await fetch(`${mock}/streams`)).json()) as Record<string, number>)[key];
  for (let i = 0; i < 40; i++) {
    if ((await now()) === n) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.equal(await now(), n);
}
