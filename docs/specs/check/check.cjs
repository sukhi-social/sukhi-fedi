// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Checks the JSON in docs/specs with CUE (https://cuelang.org).
//
//   1. Every ```cue block in a document is a file of one CUE package.
//   2. A ```json block that follows a line ending in (type `#Name`): is
//      checked against the definition #Name (`cue vet -d`).
//   3. The messages in negative.json must be rejected by the type they name.
//
// Needs `cue` on PATH (mise.toml pins it). Exits 1 on any failure, with the
// document and line.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const specs = path.resolve(__dirname, '..');

function markdownFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    if (e.name === 'node_modules') return [];
    const p = path.join(dir, e.name);
    if (e.isDirectory()) return markdownFiles(p);
    return e.name.endsWith('.md') ? [p] : [];
  });
}

const docs = markdownFiles(specs).sort();
const fence = /^```(\w*)\s*$/;
const cueParts = [];
const examples = [];

for (const doc of docs) {
  const rel = path.relative(specs, doc);
  const lines = fs.readFileSync(doc, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(fence);
    if (!m || !m[1]) continue;
    let j = i + 1;
    while (j < lines.length && lines[j] !== '```') j++;
    const body = lines.slice(i + 1, j).join('\n');
    const typed = i > 0 && lines[i - 1].match(/\(type `(#\w+)`\):\s*$/);
    if (m[1] === 'cue') cueParts.push(`// ${rel}:${i + 2}\n${body}`);
    else if (m[1] === 'json' && typed) examples.push({ where: `${rel}:${i + 2}`, def: typed[1], json: body });
    i = j;
  }
}

const negative = JSON.parse(fs.readFileSync(path.join(__dirname, 'negative.json'), 'utf8'));

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'spec-check-'));
// one file per block, so each block may have its own `import`
cueParts.forEach((body, k) => fs.writeFileSync(path.join(dir, `block${k}.cue`), 'package specs\n\n' + body + '\n'));

const blocks = cueParts.map((_, k) => path.join(dir, `block${k}.cue`));
const vet = (file, def) =>
  spawnSync('cue', ['vet', '-c', '-d', def, ...blocks, file], { encoding: 'utf8' });

let failures = 0;
const fail = (msg) => {
  failures += 1;
  console.error('FAIL ' + msg);
};

const probe = spawnSync('cue', ['vet', ...blocks], { encoding: 'utf8' });
if (probe.error) {
  console.error('cue is not installed: ' + probe.error.message);
  process.exit(1);
}
if (probe.status !== 0) fail('the CUE definitions do not compile:\n' + probe.stderr);

examples.forEach((e, k) => {
  const f = path.join(dir, `example${k}.json`);
  fs.writeFileSync(f, e.json);
  const r = vet(f, e.def);
  if (r.status !== 0) fail(`${e.where}: not a valid ${e.def}:\n${r.stderr}`);
});

negative.forEach((n, k) => {
  const f = path.join(dir, `negative${k}.json`);
  fs.writeFileSync(f, JSON.stringify(n.instance));
  const r = vet(f, '#' + n.type);
  if (r.status === 0) fail(`accepted as ${n.type}, but it must be rejected: ${n.why}`);
});

fs.rmSync(dir, { recursive: true, force: true });
console.log(
  `${docs.length} documents, ${cueParts.length} CUE blocks, ${examples.length} examples, ${negative.length} rejected cases`
);
if (failures) {
  console.error(`${failures} failure(s)`);
  process.exit(1);
}
