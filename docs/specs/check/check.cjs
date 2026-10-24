// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Checks the JSON in docs/specs.
//
//   1. Every ```json block that has a link to a *.json schema right above
//      it is validated against that schema (skeemas-markdown-validation).
//   2. Every schema printed inside a document (<!-- schema: NAME --> and
//      the ```json block after it) is identical to schemas/NAME.
//   3. The cases in negative.json are rejected by the schema they name.
//
// Exits 1 on the first kind of failure it finds, after printing all of
// that kind.

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const skeemas = require('skeemas');
skeemas.use(require('skeemas-markdown-validation'));

const specs = path.resolve(__dirname, '..');
const schemasDir = path.join(specs, 'schemas');

const schemaFiles = fs.readdirSync(schemasDir).filter((f) => f.endsWith('.schema.json')).sort();
const schemas = Object.fromEntries(
  schemaFiles.map((f) => [f, JSON.parse(fs.readFileSync(path.join(schemasDir, f), 'utf8'))])
);

function newValidator() {
  const v = skeemas();
  for (const [f, s] of Object.entries(schemas)) {
    v.addRef(f, s);
    if (s.id) v.addRef(s.id, s);
  }
  return v;
}

function markdownFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    if (e.name === 'node_modules') return [];
    const p = path.join(dir, e.name);
    if (e.isDirectory()) return markdownFiles(p);
    return e.name.endsWith('.md') ? [p] : [];
  });
}

const rel = (p) => path.relative(specs, p);
let failures = 0;
const fail = (msg) => {
  failures += 1;
  console.error('FAIL ' + msg);
};

const docs = markdownFiles(specs).sort();

// 1. examples against the schema linked above them
let examples = 0;
for (const doc of docs) {
  let tests;
  try {
    tests = newValidator().markdownTests(doc);
  } catch (e) {
    fail(`${rel(doc)}: ${e.message}`);
    continue;
  }
  for (const t of tests) {
    examples += 1;
    try {
      t.execute();
    } catch (e) {
      fail(`${rel(doc)}:${t.json.line}: ${e.message}`);
    }
  }
}

// 2. embedded copies of the schemas
let embedded = 0;
const copyRe = /<!-- schema: (\S+) -->\s*```json\n([\s\S]+?)```/g;
for (const doc of docs) {
  const text = fs.readFileSync(doc, 'utf8');
  for (const m of text.matchAll(copyRe)) {
    embedded += 1;
    const name = m[1];
    if (!schemas[name]) {
      fail(`${rel(doc)}: embedded schema names a missing file: ${name}`);
      continue;
    }
    try {
      assert.deepStrictEqual(JSON.parse(m[2]), schemas[name]);
    } catch (e) {
      fail(`${rel(doc)}: the embedded copy of ${name} differs from schemas/${name}`);
    }
  }
}

// 3. the cases that must be rejected
const negative = JSON.parse(fs.readFileSync(path.join(__dirname, 'negative.json'), 'utf8'));
for (const n of negative) {
  const r = newValidator().validate(n.instance, schemas[n.schema]);
  if (r.valid) fail(`negative case accepted by ${n.schema}: ${n.why}`);
}

console.log(
  `${docs.length} documents, ${examples} examples, ${embedded} embedded schemas, ` +
    `${schemaFiles.length} schema files, ${negative.length} negative cases`
);
if (failures) {
  console.error(`${failures} failure(s)`);
  process.exit(1);
}
