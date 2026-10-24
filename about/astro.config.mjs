// SPDX-License-Identifier: AGPL-3.0-or-later
import { defineConfig } from 'astro/config';

// 静的に書き出すだけ。about.sukhi.social に置く。
export default defineConfig({
  site: 'https://about.sukhi.social',
  output: 'static',
  trailingSlash: 'always'
});
