// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Two run.mjs result files side by side, as a Markdown table:
//
//   node scripts/load/compare.mjs base.json head.json >> "$GITHUB_STEP_SUMMARY"
//
// Exits 1 if the head run has any 5xx other than 503 (a 503 is the server
// saying "busy" on purpose; the rest are bugs).
import { readFileSync } from 'node:fs';

const [baseFile, headFile] = process.argv.slice(2);
const base = JSON.parse(readFileSync(baseFile, 'utf8'));
const head = JSON.parse(readFileSync(headFile, 'utf8'));

const cell = (r) => (r ? `${r.p50.toFixed(0)} / ${r.p95.toFixed(0)} ms, ${r.ok}/${r.requests} ok, ${r.r429} 429, ${r.r503} 503` : '–');
let bad = 0;

console.log('| users | group | base (p50 / p95) | head (p50 / p95) |');
console.log('|---|---|---|---|');
for (const hs of head.results) {
  const bs = base.results.find((s) => s.users === hs.users);
  for (const [group, row] of Object.entries(hs.rows)) {
    bad += row.r5xx;
    console.log(`| ${hs.users} | ${group} | ${cell(bs?.rows[group])} | ${cell(row)} |`);
  }
  console.log(`| ${hs.users} | **req/s** | ${bs ? bs.reqPerSec.toFixed(1) : '–'} | ${hs.reqPerSec.toFixed(1)} |`);
}
console.log('\nOne shared runner, server pinned to one core; read the ratio, not the numbers.');
if (bad) {
  console.log(`\n**${bad} responses were 5xx other than 503 on head.**`);
  process.exit(1);
}
