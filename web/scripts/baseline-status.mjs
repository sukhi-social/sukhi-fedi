// SPDX-License-Identifier: AGPL-3.0-or-later
//
// docs/CSS_SUBSET.md §4 の表を取り直すための、Baseline の状態の一覧。
//   node scripts/baseline-status.mjs
// web-features(Baseline のデータ)を取って、使っている機能の状態を出す。
// high = 広く使える / low = 最近使える / false = まだ足りない(limited)。

const FEATURES = [
  'cascade-layers', 'where', 'is', 'container-queries', 'nesting', 'has', 'subgrid',
  'color-mix', 'oklab', 'lab', 'logical-properties', 'media-query-range-syntax',
  'light-dark', 'registered-custom-properties', 'popover', 'text-wrap-balance',
  'starting-style', 'relative-color', 'content-visibility', 'view-transitions',
  'scope', 'field-sizing', 'container-style-queries', 'contrast-color', 'sibling-count',
  'anchor-positioning', 'text-wrap-pretty', 'line-clamp'
];

const res = await fetch('https://unpkg.com/web-features@latest/data.json');
if (!res.ok) throw new Error(`web-features: ${res.status}`);
const { features } = await res.json();

for (const id of FEATURES) {
  const f = features[id];
  if (!f) {
    console.log(id.padEnd(32), '(その id は無い)');
    continue;
  }
  const b = f.status?.baseline;
  console.log(id.padEnd(32), String(b).padEnd(6), f.status?.baseline_low_date ?? '');
}
