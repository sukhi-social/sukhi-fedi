// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Builds elixir/priv/legal/licenses-list.{en,ja}.html — the "everything underneath"
// list on /licenses — from what is actually installed:
//
//   Elixir/Erlang  prod dependency trees of elixir/ and delivery/
//                  (`MIX_ENV=prod mix deps.tree`), licenses read from each
//                  dep's hex_metadata.config
//   npm            `pnpm licenses list --json` in bun/, web/, web-natadeco/
//
// Grouped by the same eight categories as the thanks above it (not by
// license — the license is a small tag on each line), one collapsed <details>
// each. Every line: name (linked to the project), version, license, and the
// copyright notice from the project's own LICENSE/NOTICE (or its listed
// author when it has none). One file per language, baked in at compile time
// (see LegalController). Which category a package belongs to is the table
// below — a new dependency that is not in it is reported and lands in Tools.
//
// Needs `mix` and `pnpm` on PATH (a mise shell in this checkout), and the
// deps installed (`mix deps.get`, `pnpm install`):
//   node scripts/gen_licenses.mjs
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { extra } from './licenses_extra.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const outDir = join(root, 'elixir/priv/legal');

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const attr = (s) => esc(s).replace(/"/g, '&quot;');

// The copyright line(s) a project put in its own LICENSE/NOTICE — the notice
// MIT/BSD/ISC ask to be kept, and what Apache-2.0 points at. Only lines that
// *begin* like a notice ("Copyright (c) 2020 Name"), so the boilerplate in a
// license's own text ("the copyright owner…", "[yyyy] [name of owner]") is
// skipped, and a bare "Copyright license to…" sentence is not a notice.
function noticesFromText(text) {
  const found = [];
  for (const raw of text.split('\n')) {
    const line = raw.replace(/^[\s*#>/-]+/, '').trim();
    if (!/^(copyright\s*(\(c\)|©)|copyright\s+\d{4}|\(c\)\s*\d{4}|©|\d{4}\s*[-–—]*\s*\d{0,4}\s*(\(c\)|©))/i.test(line)) continue;
    if (/[\[{<]?(yyyy|year)[\]}>]?|owner|holder|notice\b/i.test(line)) continue;
    const who = line
      .replace(/^copyright\s*/i, '')
      .replace(/\(c\)|©/gi, ' ')
      .replace(/\s+/g, ' ')
      // a markdown link stays ("[these people](…/graphs/contributors)"): li() renders it
      .replace(/\s*<[^>]*@[^>]*>/g, '') // personal e-mail addresses stay off the page
      .replace(/\s*\([^)]*@[^)]*\)/g, '')
      .replace(/[.,;]?\s*all rights reserved\.?$/i, '') // old BSD boilerplate, not a restriction
      .trim()
      .replace(/\.$/, '');
    if (/^[\d\s,.-]*$/.test(who) || who.length > 160) continue; // a bare year, or prose
    const c = `© ${who}`;
    if (!found.includes(c)) found.push(c);
  }
  return found;
}

function copyrightLines(dir) {
  if (!existsSync(dir)) return [];
  const found = [];
  for (const f of readdirSync(dir)) {
    if (!/^(licen[sc]e|copying|notice)/i.test(f)) continue;
    let text;
    try {
      text = readFileSync(join(dir, f), 'utf8');
    } catch {
      continue; // a directory named LICENSES, say
    }
    for (const c of noticesFromText(text)) if (!found.includes(c)) found.push(c);
  }
  return found.slice(0, 3);
}

// Notices the project does not put in its own LICENSE file, supplied by hand
// (e.g. told to us by someone who knows the project). Key: package name.
const noticeOverrides = {
  'urlpattern-polyfill': '© 2020 Intel Corporation',
  protocol_ex: 'by overminddl1', // hex.pm/users/overminddl1
  canonicalize: 'by Samuel Erdtman',
};

// Where the license tag on a line should lead. The project's own LICENSE
// file when we can name it (GitHub repo + the file actually installed): that
// is the text with *this* project's copyright holder in it, which a generic
// template is not. Otherwise the SPDX page for the license id; a compound or
// non-SPDX id ("BSD", "MIT AND CC-BY-4.0") gets no link rather than a wrong one.
const licenseFileName = (dir) => {
  if (!existsSync(dir)) return null;
  for (const f of readdirSync(dir).sort()) {
    if (!/^(licen[sc]e|copying)/i.test(f)) continue;
    try {
      readFileSync(join(dir, f)); // skip a directory named LICENSES
      return f;
    } catch {
      /* directory */
    }
  }
  return null;
};

const githubRepo = (urls) => {
  for (const u of urls) {
    const m = String(u).match(/github\.com[/:]([\w.-]+)\/([\w.-]+?)(?:\.git)?(?:[/#?].*)?$/i);
    if (m) return `https://github.com/${m[1]}/${m[2]}`;
  }
  return null;
};

const SPDX_SIMPLE = /^[A-Za-z0-9.+-]+$/;
const NOT_SPDX = new Set(['BSD']);
function licenseHref(license, depDir, repoUrls) {
  const repo = githubRepo(repoUrls);
  const file = repo && licenseFileName(depDir);
  if (repo && file) return `${repo}/blob/HEAD/${file}`;
  if (SPDX_SIMPLE.test(license) && !NOT_SPDX.has(license)) return `https://spdx.org/licenses/${license}.html`;
  return null;
}

// ---- Elixir / Erlang ------------------------------------------------------

function mixDeps(dir, env) {
  const tree = execFileSync('mix', ['deps.tree', '--only', env, '--format', 'plain'], {
    cwd: join(root, dir),
    env: { ...process.env, MIX_ENV: env },
    encoding: 'utf8',
  });
  const names = new Set();
  for (const line of tree.split('\n')) {
    const m = line.match(/^[|` -]*(?:--\s+)?([a-z][a-z0-9_]*)\s/);
    if (m && line.includes('(')) names.add(m[1]);
  }
  return names;
}

function hexInfo(dir, name) {
  const depDir = join(root, dir, 'deps', name);
  const meta = join(depDir, 'hex_metadata.config');
  if (!existsSync(meta)) return null;
  const text = readFileSync(meta, 'utf8');
  const lic = text.match(/\{<<"licenses">>,\[([^\]]*)\]\}/);
  if (!lic) return null;
  const ids = [...lic[1].matchAll(/<<"([^"]+)">>/g)].map((x) => x[1]);
  if (!ids.length) return null;
  const version = text.match(/\{<<"version">>,<<"([^"]+)">>\}/)?.[1] ?? '';
  const linkPairs = [...text.matchAll(/\{<<"([^"]+)">>,\s*<<"(https?:[^"]+)">>\}/g)].map((x) => [x[1], x[2]]);
  const links = linkPairs.map(([, u]) => u);
  const maintainers = text.match(/\{<<"maintainers">>,\[([^\]]*)\]\}/);
  const people = maintainers ? [...maintainers[1].matchAll(/<<"([^"]+)">>/g)].map((x) => x[1]) : [];
  const notice =
    noticeOverrides[name] ?? copyrightLines(depDir)[0] ?? (people.length ? `by ${people.join(', ')}` : '');
  // Hex authors spell it both ways; one spelling keeps the groups merged.
  const license = ids.map((i) => i.replace(/^Apache 2\.0$/, 'Apache-2.0')).join(' OR ');
  return {
    license,
    entry: {
      name,
      version,
      href: `https://hex.pm/packages/${name}`,
      repo: githubRepo(links),
      website: linkPairs.find(([k]) => /^(website|homepage|home|site)$/i.test(k))?.[1] ?? null,
      notice,
      licenseHref: licenseHref(license, depDir, links),
    },
  };
}

// Our own code, including ojak-ex (same org, AGPL — it is not a "thank you
// to someone else" but a sibling).
const own = new Set(['sukhi_fedi', 'sukhi_delivery', 'sukhi_api', 'sukhi_shared', 'ojak']);
const elixir = new Map(); // name -> { license, entry }
const unknown = [];
// ojak is skipped by the loop below (it is not a hex package with a license
// to read) but its presence in the prod tree is what switches on its own rows,
// its Rust crates and Feder further down.
let ojakPresent = false;
for (const dir of ['elixir', 'delivery']) {
  for (const name of mixDeps(dir, 'prod')) {
    if (name === 'ojak') ojakPresent = true;
    if (own.has(name) || elixir.has(name)) continue;
    const info = hexInfo(dir, name) ?? hexInfo(dir === 'elixir' ? 'delivery' : 'elixir', name);
    if (info) elixir.set(name, info);
    else unknown.push(`${dir}/${name}`);
  }
}
// What only dev and test need (linters, test doubles…): not in the release,
// but we use it every day, so it is listed — under Tools.
for (const dir of ['elixir', 'delivery']) {
  for (const env of ['dev', 'test']) {
    for (const name of mixDeps(dir, env)) {
      if (own.has(name) || elixir.has(name)) continue;
      const info = hexInfo(dir, name) ?? hexInfo(dir === 'elixir' ? 'delivery' : 'elixir', name);
      if (info) elixir.set(name, { ...info, dev: true });
      else unknown.push(`${dir}/${name}`);
    }
  }
}

// ---- npm ------------------------------------------------------------------

// Per-platform native bindings and @types are one dependency each, not
// dozens of lines. Folded under a single readable entry.
const folds = [
  [/^@rolldown\/binding-/, '@rolldown/binding-* (platform builds of rolldown)'],
  [/^@oxc-node\/core-/, '@oxc-node/core-* (platform builds of oxc-node)'],
  [/^lightningcss-/, 'lightningcss-* (platform builds of lightningcss)'],
  [/^@types\//, '@types/* (DefinitelyTyped)'],
];

// package.json's `repository` comes as a string, "github:o/r", or { url }.
function npmRepoUrls(dir, homepage) {
  const urls = [];
  try {
    const repo = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')).repository;
    const u = typeof repo === 'string' ? repo : repo?.url;
    if (u) urls.push(u.replace(/^github:/, 'https://github.com/'));
  } catch {
    /* no package.json to read */
  }
  if (homepage) urls.push(homepage);
  return urls;
}

const npm = new Map(); // display name -> { license, entry }
for (const dir of ['bun', 'web', 'web-natadeco']) {
  const json = JSON.parse(
    execFileSync('pnpm', ['licenses', 'list', '--json'], {
      cwd: join(root, dir),
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
    }),
  );
  for (const [license, pkgs] of Object.entries(json)) {
    for (const { name, versions, paths, author, homepage } of pkgs) {
      const fold = folds.find(([re]) => re.test(name));
      const shown = fold ? fold[1] : name;
      const seen = npm.get(shown);
      if (seen) {
        // Same package from another app: keep one line, add any new version.
        for (const v of versions) {
          if (fold || seen.entry.version.split(', ').includes(v)) continue;
          seen.entry.version += `, ${v}`;
        }
        continue;
      }
      npm.set(shown, {
        license,
        entry: {
          name: shown,
          version: fold ? '' : versions.join(', '),
          href: `https://www.npmjs.com/package/${name}`,
          repo: githubRepo(npmRepoUrls(paths[0], homepage)),
          // A homepage that is just a page on GitHub is the repo again, not a website.
          website: homepage && !/github\.com/i.test(homepage) ? homepage : null,
          notice: noticeOverrides[name] ?? copyrightLines(paths[0])[0] ?? (author ? `by ${author}` : ''),
          licenseHref: licenseHref(license, paths[0], npmRepoUrls(paths[0], homepage)),
        },
      });
    }
  }
}

// ---- categories -----------------------------------------------------------

// Same order and ids as the headings in licenses.{en,ja}.md. A name here is
// the package name as listed (npm scopes included); `*` ends a prefix.
const categories = [
  { id: 'languages', en: 'Languages', ja: '言語', names: `
    decimal jason nimble_options nimble_parsec nimble_pool unicode_util_compat parse_trans uniq equivalex
    protocol_ex metrics tslib extend deepmerge es-toolkit js-yaml yaml argparse structured-field-values
    byte-encodings temporal-polyfill temporal-spec temporal-utils @js-temporal/polyfill jsbi bignumber.js
    safe-buffer setimmediate base64-js lru-cache yallist` },
  { id: 'federation', en: 'Federation', ja: '連合（フェデレーション）', names: `
    @fedify/* json_ld rdf jcs jsonld rdf-canonize canonicalize json-canon pkijs asn1js pvtsutils pvutils
    bytestreamjs @digitalbazaar/http-client @multiformats/base-x urlpattern-polyfill` },
  { id: 'web', en: 'Web', ja: 'Web', names: `
    bandit plug plug_crypto websock thousand_island ranch req finch mint hackney tesla mime mimerl idna hpax
    castore certifi ssl_verify_fun oban hammer poolboy undici undici-types node-fetch ky agent-base
    https-proxy-agent whatwg-url tr46 webidl-conversions cookie @polka/url sirv mrmime totalist uuid` },
  { id: 'data-messaging', en: 'Data & messaging', ja: 'データ・メッセージング', names: `
    ecto ecto_sql postgrex db_connection connection gnat nkeys @nats-io/* @electric-sql/* ex_aws ex_aws_s3
    sweet_xml` },
  { id: 'security', en: 'Security', ja: 'セキュリティ', names: `
    argon2_elixir comeonin wax_ cbor x509 html_sanitize_ex mochiweb web_push gen_smtp chacha20 curve25519
    ed25519 kcl poly1305 salsa20 @noble/hashes tweetnacl jwa jws ecdsa-sig-formatter
    buffer-equal-constant-time` },
  { id: 'frontend-media', en: 'Frontend & media', ja: 'フロントエンド・メディア', names: `
    svelte @sveltejs/* esrap esm-env zimmerframe locate-character magic-string is-reference aria-query
    axobject-query clsx devalue acorn @twemoji/* vix budoux leaflet uqr js.foresight position-observer
    tabbable earmark linkedom htmlparser2 domhandler domutils domelementtype dom-serializer entities
    css-select css-what boolbase nth-check uhyphen cssom html-escaper` },
  { id: 'tools', en: 'Tools', ja: 'ツール', names: `
    vite rolldown @rolldown/* @oxc-project/* @oxc-node/* lightningcss lightningcss-* postcss source-map-js
    picocolors nanoid @jridgewell/* tinyglobby fdir picomatch chokidar readdirp fsevents vitefu typescript
    svelte-check playwright playwright-core @playwright/* @types/* @standard-schema/spec @cfworker/json-schema
    detect-libc obug sade mri yargs yargs-parser cliui y18n wrap-ansi string-width strip-ansi ansi-regex
    ansi-styles color-convert color-name emoji-regex is-fullwidth-code-point require-directory
    get-caller-file escalade commander debug ms fs-extra graceful-fs jsonfile universalify pirates
    cc_precompiler elixir_make octo_fetch asn1_compiler` },
  { id: 'infrastructure', en: 'Infrastructure', ja: 'インフラ', names: `
    telemetry telemetry_metrics telemetry_metrics_prometheus_core telemetry_poller prom_ex peep
    @opentelemetry/* @logtape/* google-auth-library gaxios gcp-metadata google-artifactregistry-auth
    google-logging-utils gtoken is-stream json-bigint` },
];

const catOf = (display) => {
  const name = display.replace(/ \(.*$/, ''); // folded entries: "lightningcss-* (platform builds…)"
  for (const c of categories) {
    for (const n of c.names.split(/\s+/).filter(Boolean)) {
      if (n === name || (n.endsWith('*') && name.startsWith(n.slice(0, -1)))) return c;
    }
  }
  return null;
};

// ---- render ---------------------------------------------------------------

// A notice is plain text, except a markdown link written by the project
// itself ("© 2020 [these people](https://…/graphs/contributors)"), which keeps
// its link. Only http(s) targets become anchors.
function noticeHtml(text) {
  let out = '';
  let last = 0;
  for (const m of text.matchAll(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g)) {
    out += esc(text.slice(last, m.index)) + `<a href="${attr(m[2])}">${esc(m[1])}</a>`;
    last = m.index + m[0].length;
  }
  return out + esc(text.slice(last));
}

const li = ({ name, version, href, website, notice, license, licenseHref: lh, ref }, l) =>
  `<li><a href="${attr(href)}">${esc(name)}</a>` +
  (ref ? `<sup class="ref"><a href="#${ref}">[1]</a></sup>` : '') +
  (version ? ` <span class="v">${esc(version)}</span>` : '') +
  (lh
    ? ` <a class="l" href="${attr(lh)}">${esc(license)}</a>`
    : ` <span class="l">${esc(license)}</span>`) +
  (website ? ` <a class="w" href="${attr(website)}">${l === 'ja' ? 'ウェブサイト' : 'Website'}</a>` : '') +
  (notice ? ` <span class="c">${noticeHtml(notice)}</span>` : '') +
  '</li>';

const byCategory = new Map(categories.map((c) => [c.id, []]));
const tools = categories.find((c) => c.id === 'tools');
const uncategorized = [];
for (const map of [elixir, npm]) {
  for (const [display, { license, entry, dev }] of map) {
    const c = dev ? tools : catOf(display);
    if (!c) uncategorized.push(display);
    byCategory.get((c ?? tools).id).push({ ...entry, license });
  }
}

// ---- ojak: another project's work, and the Rust inside it -----------------

// ojak is eunha-space's (sukhi-social keeps a fork pinned by commit); ojak-ex
// is ours, the Elixir side. Both are listed — a dependency is a dependency.
if (ojakPresent) byCategory.get('federation').push(
  {
    name: 'ojak',
    ref: 'note-rust',
    version: '0.1.0',
    href: 'https://github.com/eunha-space/ojak',
    website: null,
    // Only what is certain: the org that owns the repo. ojak's LICENSE has no
    // copyright line and Cargo has no authors; the exact holder wording is being
    // asked of the author — replace this when they answer.
    notice: 'by eunha-space (ojak-sig, ojak-jsonld)',
    license: 'AGPL-3.0-only',
    licenseHref: 'https://github.com/eunha-space/ojak/blob/HEAD/LICENSE',
  },
  {
    name: 'ojak-ex',
    ref: 'note-rust',
    version: '0.1.2',
    href: 'https://github.com/sukhi-social/ojak-ex',
    website: null,
    notice: 'by sukhi-social',
    license: 'AGPL-3.0-only',
    licenseHref: 'https://github.com/sukhi-social/ojak-ex/blob/HEAD/LICENSE',
  },
);

// The crates compiled into ojak's NIF. Read from the lock ojak-ex pins
// (`cargo metadata --locked`: reads manifests, builds nothing).
const rust = [];
const ojakExDir = process.env.OJAK_EX_DIR ?? join(root, '..', 'ojak-ex');
if (!ojakPresent) {
  // not a dependency here: nothing of ojak is listed
} else if (existsSync(join(ojakExDir, 'Cargo.lock'))) {
  const meta = JSON.parse(
    execFileSync('cargo', ['metadata', '--format-version', '1', '--locked'], {
      cwd: ojakExDir,
      encoding: 'utf8',
      maxBuffer: 256 * 1024 * 1024,
    }),
  );
  for (const pkg of meta.packages) {
    if (!pkg.source?.startsWith('registry+')) continue; // ojak's own crates are listed above
    const license = (pkg.license ?? '').replace(/\//g, ' OR ').replace(/\s+/g, ' ').trim() || 'unknown';
    const dir = dirname(pkg.manifest_path);
    const authors = (pkg.authors ?? []).map((a) => a.replace(/\s*<[^>]*>/, '').trim()).filter(Boolean);
    const seen = rust.find((r) => r.name === pkg.name);
    if (seen) {
      if (!seen.version.split(', ').includes(pkg.version)) seen.version += `, ${pkg.version}`;
      continue; // one line per crate, every version it is built in
    }
    rust.push({
      name: pkg.name,
      version: pkg.version,
      href: `https://crates.io/crates/${pkg.name}`,
      repo: githubRepo([pkg.repository ?? '']),
      website: pkg.homepage && !/github\.com/i.test(pkg.homepage) ? pkg.homepage : null,
      notice: copyrightLines(dir)[0] ?? (authors.length ? `by ${authors.slice(0, 2).join(', ')}` : ''),
      license,
      licenseHref: licenseHref(license, dir, [pkg.repository ?? '']),
    });
  }
} else {
  console.warn(`ojak-ex not found at ${ojakExDir} (set OJAK_EX_DIR) — its Rust crates are left out`);
}

// ---- what no lockfile lists (licenses_extra.mjs) ---------------------------

const ghLicense = (repo) => {
  try {
    return JSON.parse(execFileSync('gh', ['api', `repos/${repo}/license`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }));
  } catch {
    return null; // no repo license on GitHub, or gh is not signed in
  }
};
const present = { ojak: ojakPresent };
for (const e of extra) {
  if (e.requires && !present[e.requires]) continue; // e.g. Feder only when ojak is confirmed
  const gh = e.repo ? ghLicense(e.repo) : null;
  const spdx = gh?.license?.spdx_id;
  const license = e.license ?? (spdx && spdx !== 'NOASSERTION' ? spdx : null);
  if (!license) {
    console.warn(`extra: no license for ${e.name} — give one in licenses_extra.mjs`);
    continue;
  }
  const text = gh?.content ? Buffer.from(gh.content, 'base64').toString('utf8') : '';
  byCategory.get(e.cat).push({
    name: e.name,
    version: e.version ?? '',
    href: e.href ?? `https://github.com/${e.repo}`,
    website: e.website ?? null,
    notice: e.notice ?? noticesFromText(text)[0] ?? '',
    license,
    licenseHref: e.licenseHref ?? gh?.html_url ?? null,
  });
}

// Where the repository is when the package is not installed here (so its
// package.json cannot say). Names checked to exist on GitHub.
const repoOverrides = {
  'es-toolkit': 'toss/es-toolkit',
  undici: 'nodejs/undici',
  'undici-types': 'nodejs/undici',
  '@sveltejs/kit': 'sveltejs/kit',
  '@sveltejs/adapter-static': 'sveltejs/kit',
  '@sveltejs/adapter-node': 'sveltejs/kit',
  '@oxc-node/core': 'oxc-project/oxc-node',
  '@oxc-node/core-* (platform builds of oxc-node)': 'oxc-project/oxc-node',
  '@types/* (DefinitelyTyped)': 'DefinitelyTyped/DefinitelyTyped',
  leaflet: 'Leaflet/Leaflet',
  lightningcss: 'parcel-bundler/lightningcss',
  'lightningcss-* (platform builds of lightningcss)': 'parcel-bundler/lightningcss',
};

// A package that is not installed here (or whose LICENSE has no readable
// notice) gets GitHub's copy of the repository's license file. Only the holder
// named *in that text* — never a guess from the repo owner.
const holderCache = new Map();
function githubNotice(repo) {
  if (!repo) return '';
  const key = repo.replace('https://github.com/', '');
  if (!holderCache.has(key)) {
    const gh = ghLicense(key);
    const text = gh?.content ? Buffer.from(gh.content, 'base64').toString('utf8') : '';
    holderCache.set(key, noticesFromText(text)[0] ?? '');
  }
  return holderCache.get(key);
}
let filledFromGitHub = 0;
for (const e of [...[...byCategory.values()].flat(), ...rust]) {
  if (e.notice && !e.notice.startsWith('by ')) continue; // a real © line wins; "by <author>" yields to one
  const n = githubNotice(e.repo ?? (repoOverrides[e.name] ? `https://github.com/${repoOverrides[e.name]}` : null));
  if (n) {
    e.notice = n;
    filledFromGitHub++;
  }
}

// A repo's license file moves (monorepos, renamed branches). Follow each file
// link once; one that does not open falls back to the SPDX page. Offline or
// rate-limited (anything that is not a plain 404) keeps the link as it was.
async function checkLicenseLinks() {
  const entries = [...[...byCategory.values()].flat(), ...rust].filter((e) => e.licenseHref?.includes('/blob/HEAD/'));
  const urls = [...new Set(entries.map((e) => e.licenseHref))];
  const dead = new Set();
  let i = 0;
  await Promise.all(
    Array.from({ length: 8 }, async () => {
      while (i < urls.length) {
        const u = urls[i++];
        try {
          const r = await fetch(u, { method: 'HEAD', redirect: 'follow', signal: AbortSignal.timeout(15000) });
          if (r.status === 404) dead.add(u);
        } catch {
          /* offline: keep */
        }
      }
    }),
  );
  for (const e of entries) {
    if (!dead.has(e.licenseHref)) continue;
    e.licenseHref = SPDX_SIMPLE.test(e.license) && !NOT_SPDX.has(e.license) ? `https://spdx.org/licenses/${e.license}.html` : null;
  }
  return dead.size;
}
const deadLinks = await checkLicenseLinks();

// The crates inside ojak, by the same ids as the page's categories (the ones
// that have no crate are simply not shown on the Rust page). A crate that is
// not named here is reported and lands in Tools.
const rustCategoryNames = {
  languages: `
    autocfg cfg-if itoa ryu-js zmij memchr libc libm libloading lazy_static smallvec spin tinyvec hashbrown
    indexmap equivalent num-bigint-dig num-integer num-iter num-traits typenum generic-array hybrid-array
    utf8_iter unicode-ident stable_deref_trait version_check rustc_version semver rustversion wasi windows-link
    r-efi cpufeatures zerocopy zerocopy-derive chrono inventory ref-cast ref-cast-impl potential_utf tinystr
    litemap writeable yoke yoke-derive zerofrom zerofrom-derive zerovec zerovec-derive zerotrie icu_*`,
  federation: 'sfv serde_json_canonicalizer iri-string bs58',
  web: 'url idna idna_adapter form_urlencoded percent-encoding base64',
  'data-messaging': 'serde serde_core serde_derive serde_json',
  security: `
    curve25519-dalek curve25519-dalek-derive ed25519 ed25519-dalek fiat-crypto rsa sha2 keccak shake digest
    crypto-common block-buffer const-oid der pkcs1 pkcs8 spki pem-rfc7468 signature subtle zeroize ml-dsa
    module-lattice sponge-cursor rand rand_chacha rand_core getrandom ppv-lite86 cmov ctutils base64ct`,
  tools: 'proc-macro2 quote syn synstructure heck displaydoc rustler rustler_codegen',
};
const rustCatOf = (name) => {
  for (const [id, names] of Object.entries(rustCategoryNames)) {
    for (const n of names.split(/\s+/).filter(Boolean)) {
      if (n === name || (n.endsWith('*') && name.startsWith(n.slice(0, -1)))) return id;
    }
  }
  return null;
};
const rustByCategory = new Map(categories.map((c) => [c.id, []]));
const rustUncategorized = [];
for (const e of rust) {
  const id = rustCatOf(e.name);
  if (!id) rustUncategorized.push(e.name);
  rustByCategory.get(id ?? 'tools').push(e);
}

const sorted = (xs) => [...xs].sort((a, b) => a.name.localeCompare(b.name, 'en'));

const block = (id, label, entries, l, labelExtra = '', open = false) =>
  `<details${open ? ' open' : ''} id="${id}"><summary>${esc(label)}${labelExtra} <span class="n">${entries.length}</span></summary>\n` +
  `<ul class="names">\n${entries.map((e) => li(e, l)).join('\n')}\n</ul>\n</details>`;

// Footnote 1 on the main page: why the Rust crates are not in the list.
const note = {
  en: (n) =>
    `<aside class="notes"><p id="note-rust"><sup>[1]</sup> ojak is written in Rust, and Rust crates tend to be small, ` +
    `so one project brings in many of them. To keep this list from filling up with them, the ${n} crates inside ojak ` +
    `are on <a href="/licenses/rust">a separate page</a>, sorted by the same categories.</p></aside>\n`,
  ja: (n) =>
    `<aside class="notes"><p id="note-rust"><sup>[1]</sup> ojak は Rust で書かれています。Rust のクレートは小さくなる傾向があり、` +
    `一つのプロジェクトがたくさん連れてきます。この一覧がそれで埋まらないように、ojak の中の ${n} 個のクレートは、` +
    `<a href="/licenses/rust?lang=ja">別のページ</a>に、同じカテゴリーで分けて載せています。</p></aside>\n`,
};

function render(l) {
  const blocks = categories.map((c) => {
    const ref = c.id === 'federation' && rust.length ? '<sup class="ref"><a href="#note-rust">[1]</a></sup>' : '';
    return block(`deps-${c.id}`, c[l], sorted(byCategory.get(c.id)), l, ref);
  });
  const total = [...byCategory.values()].reduce((n, e) => n + e.length, 0);
  return (
    `<section class="deps">\n${blocks.join('\n')}\n</section>\n` +
    (rust.length ? note[l](rust.length) : '') +
    `<!-- ${total} entries -->\n`
  );
}

// The separate page: the same categories, only those that have crates, closed
// like the main list.
function renderRust(l) {
  const blocks = categories
    .filter((c) => rustByCategory.get(c.id).length)
    .map((c) => block(`rust-${c.id}`, c[l], sorted(rustByCategory.get(c.id)), l));
  return `<section class="deps">\n${blocks.join('\n')}\n</section>\n<!-- ${rust.length} crates -->\n`;
}

const header = '<!-- Generated by scripts/gen_licenses.mjs — do not edit by hand. -->\n';
for (const l of ['en', 'ja']) {
  writeFileSync(join(outDir, `licenses-list.${l}.html`), header + render(l));
  if (rust.length) writeFileSync(join(outDir, `licenses-rust-list.${l}.html`), header + renderRust(l));
}

console.log(`${filledFromGitHub} notices taken from GitHub's license text`);
console.log(
  `elixir ${elixir.size}, npm ${npm.size}, extra ${extra.filter((e) => !e.requires || present[e.requires]).length}, rust ${rust.length} -> ` +
    [...byCategory].map(([id, e]) => `${id} ${e.length}`).join(', '),
);
if (rustUncategorized.length) console.warn(`crates not in the table (put under Tools): ${rustUncategorized.join(', ')}`);
if (uncategorized.length) console.warn(`not in the category table (put under Tools): ${uncategorized.join(', ')}`);
if (deadLinks) console.warn(`${deadLinks} license file link(s) did not open; fell back to SPDX`);
if (unknown.length) console.warn(`no license found: ${unknown.join(', ')}`);
