// Self-host the Twemoji SVGs: copy them out of the @twemoji/svg package into
// static/twemoji/svg so the build serves them at /twemoji/svg/<codepoint>.svg.
// Runs as `prebuild`, so the files are in place before adapter-static sweeps
// static/. They're not committed — regenerated from the package on each build.
import { cp, mkdir, readdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, '..', 'node_modules', '@twemoji', 'svg');
const dest = join(here, '..', 'static', 'twemoji', 'svg');

await mkdir(dest, { recursive: true });
await cp(src, dest, {
  recursive: true,
  // The package ships only `*.svg` plus a package.json / README / LICENSE;
  // keep the art, drop the metadata.
  filter: (p) => !p.endsWith('.json') && !p.toLowerCase().endsWith('.md')
});

const count = (await readdir(dest)).filter((f) => f.endsWith('.svg')).length;
console.log(`copy-twemoji: ${count} svg -> static/twemoji/svg`);
