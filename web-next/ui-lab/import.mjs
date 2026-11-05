// SPDX-License-Identifier: AGPL-3.0-or-later
// 他で作られた React + Vite のモック(Figma Make などの zip)を、そのまま並べて見られる形にする。
//
//   node import.mjs <モックの zip か、展開ずみのフォルダ> <名前>
//   → external/<名前>/src   (そのままの中身)
//     external/<名前>/dist  (静的に束ねたもの。ギャラリーはこれを見る)
//
// ほかの人・ほかのエージェントが作ったものは、信頼できない入力として扱う。
//   - zip の中の vite.config や scripts は **走らせない**。束ねるのは、ここにある設定(下の bundle())だけ。
//   - 依存は ui-lab の node_modules から引く(zip 側で pnpm install はしない = install script も走らない)。
//   - 展開先は、毎回あたらしい空のフォルダ。
// 画像や字を外のサーバから引くモックは、オフラインだと、そこだけ欠ける。確かめたいのが形なら、それで足りる。

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const [from, name] = process.argv.slice(2);
if (!from || !name || !/^[a-z0-9][a-z0-9-]*$/.test(name)) {
  console.error('使いかた: node import.mjs <zip か フォルダ> <名前(英小文字・数字・-)>');
  process.exit(2);
}

const dest = join(here, 'external', name);
const src = join(dest, 'src');
rmSync(dest, { recursive: true, force: true });
mkdirSync(src, { recursive: true });

if (statSync(from).isDirectory()) {
  cpSync(from, src, { recursive: true, filter: (p) => !/(^|\/)(node_modules|dist|\.git)(\/|$)/.test(p) });
} else {
  // -o: 上書き。展開先の外に出るパスは、unzip 自身が拒む。
  execFileSync('unzip', ['-q', '-o', resolve(from), '-d', src], { stdio: 'inherit' });
}
// zip が 1 つのフォルダに包まれていたら、ひとつ上げる。
const top = readdirSync(src).filter((f) => f !== '__MACOSX');
if (!existsSync(join(src, 'index.html')) && top.length === 1 && statSync(join(src, top[0])).isDirectory()) {
  const inner = join(src, top[0]);
  for (const f of readdirSync(inner)) cpSync(join(inner, f), join(src, f), { recursive: true });
  rmSync(inner, { recursive: true, force: true });
}
if (!existsSync(join(src, 'index.html'))) {
  console.error('index.html が見つかりません。Vite のモックではないようです。');
  process.exit(1);
}

const { build } = await import('vite');
const { default: react } = await import('@vitejs/plugin-react');
const { default: tailwindcss } = await import('@tailwindcss/vite');

const bundle = () =>
  build({
    configFile: false, // zip の設定は読まない
    root: src,
    base: './', // どこに置いても、相対で引ける
    logLevel: 'warn',
    plugins: [react(), tailwindcss()],
    resolve: { alias: { '@': join(src, 'src') } },
    build: { outDir: join(dest, 'dist'), emptyOutDir: true },
  });

// 渡されたモックには、一行の型リテラルから ; が落ちたもの(`{ a: string b: string }`)が混じることがある。
// 構文エラーで止まったときだけ、その形に限って直して、もう一度。直した行は、すべて出す。
const MISSING_SEMI = /(: (?:string|number|boolean|"[^"\n]*"(?: \| "[^"\n]*")*|[A-Z][A-Za-z]*)) (?=[a-z][A-Za-z]*\??: )/g;
function repair(dir) {
  let n = 0;
  for (const f of readdirSync(dir, { recursive: true })) {
    if (!/\.tsx?$/.test(f) || f.includes('node_modules')) continue;
    const file = join(dir, f);
    const before = readFileSync(file, 'utf8');
    const after = before
      .split('\n')
      .map((line, i) => {
        const fixed = line.replace(MISSING_SEMI, '$1; ');
        if (fixed !== line) console.log(`  直した ${f}:${i + 1}  ${fixed.trim()}`);
        n += fixed !== line;
        return fixed;
      })
      .join('\n');
    if (after !== before) writeFileSync(file, after);
  }
  return n;
}

try {
  await bundle();
} catch (e) {
  if (!/semicolon/.test(String(e?.message ?? e)) || repair(join(src, 'src')) === 0) throw e;
  await bundle();
}

console.log(`できました: external/${name}/dist  (ギャラリーに「${name}」として並びます)`);
