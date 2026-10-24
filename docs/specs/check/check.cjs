// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Checks the JSON in docs/specs.
//
//   1. Every ```js block in a document is JSDoc (@typedef ...). All of them
//      are put in one file and compiled with `checkJs` and `strict`.
//   2. A ```json block that follows a line ending in (type `Name`): is
//      added to that file as `/** @type {Name} */ const x = <the JSON>`,
//      so the compiler checks it against the type.
//   3. negative.js holds messages the types must reject (`@ts-expect-error`).
//
// Exits 1 if the compiler reports anything, with the document and line.

const fs = require('fs');
const os = require('os');
const path = require('path');
const ts = require('typescript');

const specs = path.resolve(__dirname, '..');

function markdownFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    if (e.name === 'node_modules') return [];
    const p = path.join(dir, e.name);
    if (e.isDirectory()) return markdownFiles(p);
    return e.name.endsWith('.md') ? [p] : [];
  });
}

// out: lines of the generated file; origin[i] = where line i came from
const out = [];
const origin = [];
const add = (line, where) => {
  out.push(line);
  origin.push(where);
};

const docs = markdownFiles(specs).sort();
const fence = /^```(\w*)\s*$/;
let types = 0;
let examples = 0;

for (const doc of docs) {
  const rel = path.relative(specs, doc);
  const lines = fs.readFileSync(doc, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(fence);
    if (!m || !m[1]) continue;
    let j = i + 1;
    while (j < lines.length && lines[j] !== '```') j++;
    const body = lines.slice(i + 1, j);
    const typed = i > 0 && lines[i - 1].match(/\(type `(\w+)`\):\s*$/);
    if (m[1] === 'js') {
      types += 1;
      body.forEach((l, k) => add(l, `${rel}:${i + 2 + k}`));
    } else if (m[1] === 'json' && typed) {
      examples += 1;
      add(`/** @type {${typed[1]}} */`, `${rel}:${i + 1}`);
      add(`const example${examples} = `, `${rel}:${i + 1}`);
      body.forEach((l, k) => add(l, `${rel}:${i + 2 + k}`));
      add(';', `${rel}:${j + 1}`);
    }
    i = j;
  }
}

// negative.js is appended whole; its errors are marked by @ts-expect-error
const negFile = path.join(__dirname, 'negative.js');
const neg = fs.readFileSync(negFile, 'utf8').split('\n');
const negative = neg.filter((l) => l.trim() === '// @ts-expect-error').length;
neg.forEach((l, k) => add(l, `check/negative.js:${k + 1}`));

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'spec-check-'));
const file = path.join(dir, 'specs.js');
fs.writeFileSync(file, '// @ts-check\n' + out.join('\n') + '\n');

const program = ts.createProgram([file], {
  allowJs: true,
  checkJs: true,
  noEmit: true,
  strict: true,
  target: ts.ScriptTarget.ES2022,
  types: [],
  lib: ['lib.es2022.d.ts'],
});
const diagnostics = ts.getPreEmitDiagnostics(program);
fs.rmSync(dir, { recursive: true, force: true });

let failures = 0;
for (const d of diagnostics) {
  failures += 1;
  const text = ts.flattenDiagnosticMessageText(d.messageText, '\n');
  let where = '';
  if (d.file && d.start !== undefined) {
    const line = d.file.getLineAndCharacterOfPosition(d.start).line; // 0-based; line 0 is the @ts-check comment
    where = (origin[line - 1] || `line ${line}`) + ': ';
  }
  console.error(`FAIL ${where}${text}`);
}

console.log(
  `${docs.length} documents, ${types} type blocks, ${examples} examples, ${negative} rejected cases`
);
if (failures) {
  console.error(`${failures} failure(s)`);
  process.exit(1);
}
