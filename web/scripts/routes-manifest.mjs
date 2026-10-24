// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Say which pages this build has, so the server need not be told twice.
//
// The Elixir gateway answers a browser GET for a page with the SPA shell;
// it used to know *which* paths are pages from a hand-kept list in
// router.ex, and a page added here but not there came up 404 on a direct
// link or a reload (lists, requests, clips, ... each learned it the hard
// way). Now the build writes `routes.json` next to the assets, from
// SvelteKit's own route table, and the gateway reads it
// (SukhiFedi.Web.SpaRoutes). Add a `+page.svelte` and the route exists.
//
//   { "routes": ["/", "/lists/[id]", "/@[acct]", ...] }
//
// The ids are SvelteKit's, unchanged: `[x]` one segment, `[...x]` the rest,
// `(group)` no segment at all. Endpoints (`+server.ts`) are not pages and
// are left out.
//
// Wrap the adapter in vite.config.ts; `dir` is where the client assets
// land, the directory that gets served (and pushed):
//
//   adapter: withRoutesManifest(adapter({ ... }), 'build')
import { writeFileSync } from "node:fs";
import { join } from "node:path";

/**
 * @param {import('@sveltejs/kit').Adapter} adapter
 * @param {string} dir
 * @returns {import('@sveltejs/kit').Adapter}
 */
export function withRoutesManifest(adapter, dir) {
  return {
    ...adapter,
    async adapt(builder) {
      await adapter.adapt(builder);

      const routes = builder.routes
        .filter((route) => route.page)
        .map((route) => route.id)
        .sort();

      writeFileSync(join(dir, "routes.json"), JSON.stringify({ routes }, null, 2) + "\n");
      builder.log.minor(`routes manifest: ${routes.length} pages`);
    },
  };
}
