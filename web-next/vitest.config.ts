// SPDX-License-Identifier: AGPL-3.0-or-later
// Only for the benchmarks (`pnpm bench`). The tests stay on `node --test`.
import codspeedPlugin from '@codspeed/vitest-plugin';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [codspeedPlugin()],
  test: {
    benchmark: {
      include: ['bench/**/*.bench.ts']
    }
  }
});
