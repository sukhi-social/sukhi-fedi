// SPDX-License-Identifier: AGPL-3.0-or-later
// sw/sw.js(Serwist)を、ひとつのファイル public/sw.js に束ねる。web-next で唯一の、ビルド。
//   node scripts/build-sw.mjs
// dev / Docker build が呼ぶ。サーバー本体(server/)は、これまでどおり、ビルドなし。

import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';

const root = new URL('../', import.meta.url);

await build({
  entryPoints: [fileURLToPath(new URL('sw/sw.js', root))],
  outfile: fileURLToPath(new URL('public/sw.js', root)),
  bundle: true,
  minify: true,
  format: 'iife',
  target: 'es2022',
  legalComments: 'none',
  define: { 'process.env.NODE_ENV': '"production"' }
});

console.log('built public/sw.js');
