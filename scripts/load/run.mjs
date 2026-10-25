// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Load test for the "stays usable when crowded" work (TODO.md, 0.5 OCPU).
// Node 24, no dependencies. Read-only: it only GETs.
//
//   node scripts/load/run.mjs --base http://127.0.0.1:4000 --stages 10,50,100 --seconds 60
//
// Each virtual user lives behind its own address (`cf-connecting-ip:
// 203.0.113.N`), reads roughly once per `--think` seconds, and picks from a
// mix shaped like the 2026-10-25 run: mostly the public timeline, some
// instance info and nodeinfo, a SPA shell load now and then (the page that
// must still arrive while the API is limited), and, with `--token`, the
// logged-in home timeline (the one that stayed 503 after the run).
//
// It prints one table per stage, by route group (the same groups the
// server's metrics use, see Web/RouteGroup), and writes the raw numbers to
// `--out` (default scripts/load/out/<timestamp>.json) so runs compare.
//
// With `--metrics-token` it also reads `/metrics` before and after each
// stage and prints how the server's own counters moved (rate-limit
// denials, plugin RPC outcomes, DB pool queue time).
//
// Options
//   --base URL          server to hit (default http://127.0.0.1:4000)
//   --stages 10,50,100  concurrent users per stage
//   --seconds 60        length of each stage
//   --think 1           mean seconds between one user's requests
//   --token T           bearer for the home timeline (omit: skipped)
//   --metrics-token T   bearer for /metrics (omit: skipped)
//   --spread            give every user its own cf-connecting-ip (default);
//                       --no-spread puts all of them behind one address,
//                       which is how the per-IP limit shows itself
//   --allow-remote      required when --base is not a local address
//   --out FILE

import { parseArgs } from 'node:util';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const { values: o } = parseArgs({
  options: {
    base: { type: 'string', default: 'http://127.0.0.1:4000' },
    stages: { type: 'string', default: '10,50,100' },
    seconds: { type: 'string', default: '60' },
    think: { type: 'string', default: '1' },
    token: { type: 'string' },
    'metrics-token': { type: 'string' },
    spread: { type: 'boolean', default: true },
    'no-spread': { type: 'boolean', default: false },
    'allow-remote': { type: 'boolean', default: false },
    out: { type: 'string' }
  }
});

const base = new URL(o.base);
const local = ['localhost', '127.0.0.1', '[::1]'].includes(base.hostname);
if (!local && !o['allow-remote']) {
  console.error(`refusing to load ${base.host}: not a local address (pass --allow-remote if it is yours)`);
  process.exit(2);
}

const stages = o.stages.split(',').map(Number);
const seconds = Number(o.seconds);
const think = Number(o.think);
const spread = o.spread && !o['no-spread'];

// [group, weight, path, needs token, html]
const MIX = [
  ['timeline_public', 5, '/api/v1/timelines/public?limit=20', false, false],
  ['api', 1, '/api/v1/instance', false, false],
  ['federation', 1, '/nodeinfo/2.1', false, false],
  ['shell', 1, '/', false, true],
  ['timeline_home', 3, '/api/v1/timelines/home?limit=20', true, false]
].filter((m) => !m[3] || o.token);
const total = MIX.reduce((n, m) => n + m[1], 0);

function pick() {
  let r = Math.random() * total;
  for (const m of MIX) if ((r -= m[1]) < 0) return m;
  return MIX[0];
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pct = (xs, p) => (xs.length ? xs[Math.min(xs.length - 1, Math.floor(xs.length * p))] : NaN);

async function user(id, stop, rec) {
  const ip = spread ? `203.0.113.${(id % 250) + 1}` : '203.0.113.1';
  await sleep(Math.random() * think * 1000);
  while (Date.now() < stop) {
    const [group, , path, , html] = pick();
    const headers = { 'cf-connecting-ip': ip, accept: html ? 'text/html' : 'application/json' };
    if (o.token && path.includes('/home')) headers.authorization = `Bearer ${o.token}`;
    const t0 = performance.now();
    let status = 0;
    try {
      const res = await fetch(new URL(path, base), { headers, signal: AbortSignal.timeout(15_000) });
      await res.arrayBuffer();
      status = res.status;
    } catch {
      status = 0; // timeout or connection refused
    }
    const ms = performance.now() - t0;
    (rec[group] ??= []).push({ status, ms });
    await sleep(think * 1000 * (0.5 + Math.random()));
  }
}

async function scrape() {
  if (!o['metrics-token']) return null;
  try {
    const res = await fetch(new URL('/metrics', base), {
      headers: { authorization: `Bearer ${o['metrics-token']}` }
    });
    return res.ok ? parseProm(await res.text()) : null;
  } catch {
    return null;
  }
}

function parseProm(text) {
  const m = new Map();
  for (const line of text.split('\n')) {
    if (!line || line.startsWith('#')) continue;
    const i = line.lastIndexOf(' ');
    m.set(line.slice(0, i), Number(line.slice(i + 1)));
  }
  return m;
}

// How the server's own counters moved: sum every series whose name starts
// with `prefix` (labels folded), after minus before.
function moved(before, after, prefix) {
  if (!before || !after) return null;
  const sum = (m) => [...m].filter(([k]) => k.startsWith(prefix)).reduce((n, [, v]) => n + v, 0);
  return sum(after) - sum(before);
}

function report(users, rec, elapsed) {
  console.log(`\n── ${users} users, ${seconds}s ──`);
  console.log('group            req   ok%  429   503   5xx  err   p50ms   p95ms');
  const rows = {};
  const all = [];
  for (const [group, xs] of Object.entries(rec)) {
    const ms = xs.map((x) => x.ms).sort((a, b) => a - b);
    const n = (f) => xs.filter(f).length;
    const row = {
      requests: xs.length,
      ok: n((x) => x.status >= 200 && x.status < 400),
      r429: n((x) => x.status === 429),
      r503: n((x) => x.status === 503),
      r5xx: n((x) => x.status >= 500 && x.status !== 503),
      err: n((x) => x.status === 0),
      p50: pct(ms, 0.5),
      p95: pct(ms, 0.95)
    };
    rows[group] = row;
    all.push(...xs);
    console.log(
      `${group.padEnd(15)} ${String(row.requests).padStart(5)} ${((100 * row.ok) / row.requests).toFixed(0).padStart(4)} ` +
        `${String(row.r429).padStart(4)} ${String(row.r503).padStart(5)} ${String(row.r5xx).padStart(5)} ${String(row.err).padStart(4)} ` +
        `${row.p50.toFixed(0).padStart(7)} ${row.p95.toFixed(0).padStart(7)}`
    );
  }
  const okAll = all.filter((x) => x.status >= 200 && x.status < 400).length;
  console.log(`total ${all.length} req, ${((100 * okAll) / all.length).toFixed(0)}% ok, ${(all.length / elapsed).toFixed(1)} req/s`);
  return { users, seconds, rows, reqPerSec: all.length / elapsed };
}

const results = [];
for (const users of stages) {
  const before = await scrape();
  const rec = {};
  const start = Date.now();
  const stop = start + seconds * 1000;
  await Promise.all(Array.from({ length: users }, (_, i) => user(i, stop, rec)));
  const stage = report(users, rec, (Date.now() - start) / 1000);
  const after = await scrape();
  if (before && after) {
    stage.server = {
      rateLimitDenied: moved(before, after, 'sukhi_fedi_rate_limit_deny_total'),
      rpcCalls: moved(before, after, 'sukhi_fedi_rpc_call_duration_milliseconds_count'),
      rpcTimeouts: moved(before, after, 'sukhi_fedi_rpc_call_duration_milliseconds_count{result="timeout"'),
      poolQueueSeconds: moved(before, after, 'sukhi_fedi_prom_ex_ecto_repo_query_queue_time_milliseconds_sum')
    };
    console.log('server:', JSON.stringify(stage.server));
  }
  results.push(stage);
  await sleep(5000); // let queues drain between stages
}

const out =
  o.out ??
  join(dirname(fileURLToPath(import.meta.url)), 'out', `${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify({ base: o.base, spread, think, results }, null, 2));
console.log(`\nwrote ${out}`);
