// SPDX-License-Identifier: AGPL-3.0-or-later
//
// HTML / CSS の「使える部分」の検査 ── docs/CSS_SUBSET.md の規則を機械で見る。
//
//   pnpm run css-check              # いまの違反が、baseline を超えていないか(超えたら失敗)
//   pnpm run css-check -- --report  # 規則ごと・ファイルごとの数を出す(失敗しない)
//   pnpm run css-check -- --update  # baseline を書き直す(減ったときだけ、手で)
//
// baseline は「いま有る違反の数」の記録。新しい違反を増やさない(ratchet)ための
// もので、規則を緩める道具ではない。規則の置き場は RULES の一か所。

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import postcss from 'postcss';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const SRC = join(ROOT, 'src');
const BASELINE = join(ROOT, 'css-subset.baseline.json');
const argv = new Set(process.argv.slice(2));

// 色の素(生の色)を置いてよい場所。環境(tokens)を作る層だけ。
const TOKEN_FILES = new Set(['src/styles/tokens.css']);

// ── 規則 ────────────────────────────────────────────────────────────
// id は docs/CSS_SUBSET.md の見出しの番号と同じ。
const RULES = {
  'no-important': '!important は使わない(打ち消しは、層と低い詳細度で要らなくする)',
  'no-id-selector': 'id セレクタは使わない(詳細度が跳ねる)',
  'no-global': ':global() で、よその部品の中を書き換えない(環境の値を渡す)',
  'no-margin': 'margin で外の余白を持たない(外の余白は、親の gap と padding)',
  'logical-only': '物理の向き(left / right / top / bottom)ではなく、論理の向きを使う',
  'no-float': 'float / clear は使わない(flex / grid)',
  'viewport-width-query': '幅の @media ではなく、@container と範囲構文を使う(利用者の設定だけ @media)',
  'no-vendor-prefix': 'ベンダー接頭辞は書かない(autoprefixer 不要の範囲だけ使う)',
  'no-raw-color': '色は tokens の外では、生の値で書かない(環境の値を読む)',
  'font-size-unit': 'font-size を px で固定しない(rem と clamp)',
  'selector-depth': 'セレクタは 2 つの塊まで(部品の外へ手を伸ばさない)',
  'no-numeric-z-index': 'z-index は、数字ではなく tokens の名前で',
  'inline-style-props': 'style 属性は、カスタムプロパティ(--x)を渡すときだけ',
  'global-unlayered': '全体の CSS(src/styles)は @layer の中に置く(部品の scoped な CSS が、詳細度の勝負なしで勝つ)',
  'no-click-on-div': '押せるものは <button> / <a>(div や span に onclick を付けない)'
};

// 規則の例外(論理でなく、現状の限界のため)。理由を書く。
const ALLOW = {
  // 複数行の省略は、-webkit-line-clamp しか道が無い(line-clamp は Baseline に未到達)
  'no-vendor-prefix': (prop, value) =>
    /^-webkit-(line-clamp|box-orient)$/.test(prop) ||
    value.includes('-webkit-box') ||
    /^-webkit-(mask|mask-image)$/.test(prop) // mask は接頭辞なしが Baseline。移行まで
};

const found = []; // { rule, file, line, text }
const add = (rule, file, line, text) => found.push({ rule, file, line, text: text.slice(0, 90) });

// ── ファイル集め ────────────────────────────────────────────────────
function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (/\.(css|svelte)$/.test(name)) out.push(p);
  }
  return out;
}

// .svelte から <style> の中身と、その行のずれを取り出す。
function styleBlocks(text) {
  const blocks = [];
  const re = /<style[^>]*>([\s\S]*?)<\/style>/g;
  let m;
  while ((m = re.exec(text))) {
    const startLine = text.slice(0, m.index + m[0].indexOf('>') + 1).split('\n').length - 1;
    blocks.push({ css: m[1], offset: startLine });
  }
  return blocks;
}

// ── CSS の検査 ──────────────────────────────────────────────────────
const PHYSICAL_PROPS =
  /^(margin|padding|border)-(left|right|top|bottom)(-(width|style|color|radius))?$|^(left|right|top|bottom)$|^border-(top|bottom)-(left|right)-radius$/;
const MARGIN_PROPS = /^margin(-(top|right|bottom|left|block|inline)(-(start|end))?)?$/;

function checkCss(file, css, offset) {
  let root;
  try {
    root = postcss.parse(css);
  } catch (e) {
    add('parse-error', file, 0, String(e.message ?? e));
    return;
  }
  const L = (node) => (node.source?.start?.line ?? 1) + offset;

  // 全体の CSS(src/styles/*.css)は、@layer の中に置く。外に出た規則を数える。
  if (/^src\/styles\/.*\.css$/.test(file)) {
    for (const node of root.nodes ?? []) {
      const loose = node.type === 'rule' || (node.type === 'atrule' && /^(media|supports|container)$/.test(node.name));
      if (loose) add('global-unlayered', file, L(node), node.type === 'rule' ? node.selector : `@${node.name} ${node.params}`);
    }
  }

  root.walkAtRules((at) => {
    if (at.name === 'media' && /\b(min-|max-)?width\b/.test(at.params) && !/prefers-|hover|pointer|forced-colors|print/.test(at.params)) {
      add('viewport-width-query', file, L(at), `@media ${at.params}`);
    }
  });

  root.walkRules((rule) => {
    const sel = rule.selector;
    if (/!important/.test(rule.toString()) === false) {
      // placeholder: !important は decl で数える
    }
    // id セレクタ(属性セレクタ内の # は除く)
    if (/(^|[\s>+~,(])#[A-Za-z_-]/.test(sel.replace(/\[[^\]]*\]/g, ''))) add('no-id-selector', file, L(rule), sel);
    if (/:global\(/.test(sel)) add('no-global', file, L(rule), sel);
    // 部品の外へ手を伸ばす深さ: 結合子で分けた塊の数(:where() と :is() の中は 1 つと数える)
    const flat = sel.replace(/:(where|is|not|has)\([^)]*\)/g, ':$1()').replace(/\[[^\]]*\]/g, '[]');
    for (const one of flat.split(',')) {
      const parts = one.trim().split(/\s*[>+~]\s*|\s+/).filter(Boolean);
      // :global(...) のあとの塊は数えない(no-global が別に数える)
      if (parts.length > 2) add('selector-depth', file, L(rule), one.trim());
    }
  });

  root.walkDecls((d) => {
    const line = L(d);
    const prop = d.prop;
    const value = d.value;
    // 例外: 動きを減らす設定は、利用者の意思が最優先。view transition の擬似要素は
    // 作者の規則より後に UA が足すので、ここだけ !important が要る。
    const inReducedMotion = (() => {
      for (let n = d.parent; n; n = n.parent) if (n.type === 'atrule' && n.name === 'media' && /prefers-reduced-motion/.test(n.params)) return true;
      return false;
    })();
    if (d.important && !inReducedMotion) add('no-important', file, line, `${prop}: ${value} !important`);
    if (MARGIN_PROPS.test(prop) && !/^(auto|0|0 auto|auto 0)$/.test(value.trim())) add('no-margin', file, line, `${prop}: ${value}`);
    if (PHYSICAL_PROPS.test(prop) && !/^(0)$/.test(value.trim()) && !MARGIN_PROPS.test(prop)) add('logical-only', file, line, `${prop}: ${value}`);
    if (MARGIN_PROPS.test(prop) && /-(left|right|top|bottom)$/.test(prop)) add('logical-only', file, line, `${prop}: ${value}`);
    if (prop === 'text-align' && /^(left|right)$/.test(value.trim())) add('logical-only', file, line, `${prop}: ${value}`);
    if (prop === 'float' || prop === 'clear') add('no-float', file, line, `${prop}: ${value}`);
    if (/^-(webkit|moz|ms|o)-/.test(prop) || /(^|[\s(,])-(webkit|moz|ms)-[a-z]/.test(value)) {
      if (!(ALLOW['no-vendor-prefix'] && ALLOW['no-vendor-prefix'](prop, value))) add('no-vendor-prefix', file, line, `${prop}: ${value}`);
    }
    if (!TOKEN_FILES.has(file) && /#[0-9a-fA-F]{3,8}\b|\b(rgb|rgba|hsl|hsla)\(/.test(value) && !prop.startsWith('--')) {
      add('no-raw-color', file, line, `${prop}: ${value}`);
    }
    if (prop === 'font-size' && /^\d+(\.\d+)?px$/.test(value.trim())) add('font-size-unit', file, line, `${prop}: ${value}`);
    if (prop === 'z-index' && /^-?\d+$/.test(value.trim())) add('no-numeric-z-index', file, line, `${prop}: ${value}`);
  });
}

// ── マークアップの検査(.svelte のテンプレート部分) ─────────────────
function checkMarkup(file, text) {
  const body = text.replace(/<style[^>]*>[\s\S]*?<\/style>/g, (m) => m.replace(/[^\n]/g, ' '))
                   .replace(/<script[^>]*>[\s\S]*?<\/script>/g, (m) => m.replace(/[^\n]/g, ' '));
  const lines = body.split('\n');
  lines.forEach((ln, i) => {
    // style="…": カスタムプロパティ(--x)だけを置く。{…} の動的な値は中身を見る。
    for (const m of ln.matchAll(/\sstyle="([^"]*)"/g)) {
      const decls = m[1].split(';').map((s) => s.trim()).filter(Boolean);
      for (const decl of decls) {
        const name = decl.split(':')[0].trim();
        if (name && !name.startsWith('--') && !name.startsWith('{')) add('inline-style-props', file, i + 1, `style="${m[1]}"`);
      }
    }
    if (/<(div|span|li|p|section|article|header|footer|main)\b[^>]*\sonclick=/.test(ln)) add('no-click-on-div', file, i + 1, ln.trim());
  });
}

// ── 実行 ────────────────────────────────────────────────────────────
for (const p of walk(SRC)) {
  const file = relative(ROOT, p);
  const text = readFileSync(p, 'utf8');
  if (p.endsWith('.css')) checkCss(file, text, 0);
  else {
    for (const b of styleBlocks(text)) checkCss(file, b.css, b.offset);
    checkMarkup(file, text);
  }
}

// 数える: 規則 × ファイル
const counts = {};
for (const f of found) {
  counts[f.rule] ??= {};
  counts[f.rule][f.file] = (counts[f.rule][f.file] ?? 0) + 1;
}
const total = (rule) => Object.values(counts[rule] ?? {}).reduce((a, b) => a + b, 0);

if (argv.has('--report')) {
  console.log('規則ごとの違反(いま):\n');
  for (const rule of Object.keys(RULES)) {
    const files = Object.entries(counts[rule] ?? {}).sort((a, b) => b[1] - a[1]);
    console.log(`${String(total(rule)).padStart(5)}  ${rule.padEnd(22)} ${RULES[rule]}`);
    for (const [f, n] of files.slice(0, 3)) console.log(`         ${String(n).padStart(4)}  ${f}`);
  }
  console.log(`\n合計 ${found.length}`);
  if (counts['parse-error']) console.log('\n読めなかったもの:', counts['parse-error']);
  process.exit(0);
}

if (argv.has('--update')) {
  // 規則も、ファイルも、名前順にそろえて書く(差分が読めるように)。
  const sorted = Object.fromEntries(
    Object.keys(counts).sort().map((r) => [r, Object.fromEntries(Object.entries(counts[r]).sort(([a], [b]) => a.localeCompare(b)))])
  );
  writeFileSync(BASELINE, JSON.stringify(sorted, null, 2) + '\n');
  console.log(`baseline を書いた(合計 ${found.length})`);
  process.exit(0);
}

const base = existsSync(BASELINE) ? JSON.parse(readFileSync(BASELINE, 'utf8')) : {};
const worse = [];
for (const [rule, files] of Object.entries(counts)) {
  for (const [file, n] of Object.entries(files)) {
    const was = base[rule]?.[file] ?? 0;
    if (n > was) worse.push({ rule, file, was, n });
  }
}
if (worse.length) {
  console.error('新しい違反が増えました(docs/CSS_SUBSET.md):\n');
  for (const w of worse) {
    console.error(`  ${w.rule}  ${w.file}  ${w.was} → ${w.n}   ${RULES[w.rule] ?? ''}`);
    for (const f of found.filter((x) => x.rule === w.rule && x.file === w.file).slice(-(w.n - w.was))) console.error(`      L${f.line}  ${f.text}`);
  }
  process.exit(1);
}
const gone = [];
for (const [rule, files] of Object.entries(base)) for (const [file, was] of Object.entries(files)) {
  const n = counts[rule]?.[file] ?? 0;
  if (n < was) gone.push(`${rule} ${file} ${was} → ${n}`);
}
console.log(`css-check: 新しい違反なし(合計 ${found.length})` + (gone.length ? `。減ったぶんは baseline に反映できます(--update): ${gone.length} か所` : ''));
