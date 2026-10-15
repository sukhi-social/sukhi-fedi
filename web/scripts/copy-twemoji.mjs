// Self-host the Twemoji SVGs: copy them out of the @twemoji/svg package into
// static/twemoji/svg so the build serves them at /twemoji/svg/<codepoint>.svg.
// Runs as `prebuild`, so the files are in place before adapter-static sweeps
// static/. They're not committed — regenerated from the package on each build.
import { cp, mkdir, readdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
// pnpm links node_modules/@twemoji/svg into its store; cp would copy the link.
const src = await realpath(join(here, '..', 'node_modules', '@twemoji', 'svg'));
const dest = join(here, '..', 'static', 'twemoji', 'svg');

// The copy is ~3.7k files; skip it when dest was already filled from this
// exact package version (stamp file next to the svg dir).
const stamp = join(dest, '..', '.stamp');
const { version } = JSON.parse(await readFile(join(src, 'package.json'), 'utf8'));
if ((await readFile(stamp, 'utf8').catch(() => '')) === version) {
  console.log(`copy-twemoji: up to date (@twemoji/svg ${version})`);
  process.exit(0);
}

await mkdir(dest, { recursive: true });
await cp(src, dest, {
  recursive: true,
  // The package ships only `*.svg` plus a package.json / README / LICENSE;
  // keep the art, drop the metadata.
  filter: (p) => !p.endsWith('.json') && !p.toLowerCase().endsWith('.md')
});

const count = (await readdir(dest)).filter((f) => f.endsWith('.svg')).length;
console.log(`copy-twemoji: ${count} svg -> static/twemoji/svg`);
await writeFile(stamp, version);
