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
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/**
 * SvelteKit route id → the gateway's path patterns (SukhiFedi.Web.Upstreams):
 * `[x]` one segment (`:x`; `@[acct]` → `@:acct`), `[...x]` the rest (`*`),
 * `[[x]]` optional (the path with and without it), `(group)` no segment.
 *
 * @param {string} id
 * @returns {string[]}
 */
export function toClaimPaths(id) {
  let paths = [[]];
  for (const seg of id.split("/").filter((s) => s && !/^\(.*\)$/.test(s))) {
    if (/^\[\[.+\]\]$/.test(seg)) {
      const name = seg.slice(2, -2);
      paths = paths.flatMap((p) => [p, [...p, ":" + name]]);
    } else if (/^\[\.\.\..+\]$/.test(seg)) {
      paths = paths.map((p) => [...p, "*"]);
    } else {
      paths = paths.map((p) => [...p, seg.replace(/\[([^\]]+)\]/, ":$1")]);
    }
  }
  return [...new Set(paths.map((p) => "/" + p.join("/")))];
}

/**
 * The static `/.sukhi/web.json` the gateway reads (see Upstreams): which
 * paths this build answers. Built from the same route table as routes.json,
 * so there is no second list.
 *
 * @param {string[]} routeIds
 */
export function webManifest(routeIds) {
  const pages = routeIds.flatMap(toClaimPaths);
  const assets = ["/_app/*", "/twemoji/*"];
  return {
    name: "web-simple",
    claims: [...new Set([...pages, ...assets])].sort().map((path) => ({ path })),
    // The SPA runs in the browser and talks to the gateway itself; this
    // server never needs a cookie.
    cookies: [],
  };
}

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
      mkdirSync(join(dir, ".sukhi"), { recursive: true });
      writeFileSync(
        join(dir, ".sukhi", "web.json"),
        JSON.stringify(webManifest(routes), null, 2) + "\n",
      );
      builder.log.minor(`routes manifest: ${routes.length} pages`);
    },
  };
}
