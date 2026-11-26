// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One route group, a fixed number of requests: the unit CodSpeed times (codspeed.yml).
// run.mjs measures latency under a crowd; this measures how long a fixed amount of work takes,
// which is what a walltime benchmark can hold still.
//
//   node scripts/load/bench.mjs public [--requests 400] [--concurrency 16]
//
// Groups: public (public timeline), home (home timeline, needs LOAD_TOKEN_FILE), instance,
// nodeinfo. Environment: BASE (default http://127.0.0.1:4000), LOAD_TOKEN_FILE.
// Exits 1 unless 99% of the requests answered 2xx/3xx, so a broken server is a failed benchmark
// and not a fast one.
import { parseArgs } from 'node:util';
import { readFileSync } from 'node:fs';

const { values: o, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    requests: { type: 'string', default: '400' },
    concurrency: { type: 'string', default: '16' }
  }
});

const PATHS = {
  public: '/api/v1/timelines/public?limit=20',
  home: '/api/v1/timelines/home?limit=20',
  instance: '/api/v1/instance',
  nodeinfo: '/nodeinfo/2.1'
};
const group = positionals[0];
const path = PATHS[group];
if (!path) {
  console.error(`group is one of ${Object.keys(PATHS).join(', ')}`);
  process.exit(2);
}

const base = new URL(process.env.BASE ?? 'http://127.0.0.1:4000');
const total = Number(o.requests);
const workers = Number(o.concurrency);
const tokens = group === 'home' ? readFileSync(process.env.LOAD_TOKEN_FILE, 'utf8').split('\n').filter(Boolean) : [];
if (group === 'home' && tokens.length === 0) {
  console.error('home needs LOAD_TOKEN_FILE');
  process.exit(2);
}

let next = 0;
let ok = 0;
async function worker(id) {
  for (;;) {
    const n = next++;
    if (n >= total) return;
    // its own address per request, as run.mjs does, so the per-IP limit is not what is measured
    const headers = { 'cf-connecting-ip': `203.0.113.${(n % 250) + 1}`, accept: 'application/json' };
    if (tokens.length) headers.authorization = `Bearer ${tokens[n % tokens.length]}`;
    try {
      const res = await fetch(new URL(path, base), { headers, signal: AbortSignal.timeout(15_000) });
      await res.arrayBuffer();
      if (res.status >= 200 && res.status < 400) ok++;
    } catch {}
  }
}

await Promise.all(Array.from({ length: workers }, (_, i) => worker(i)));
if (ok < total * 0.99) {
  console.error(`${group}: only ${ok}/${total} requests answered 2xx/3xx`);
  process.exit(1);
}
