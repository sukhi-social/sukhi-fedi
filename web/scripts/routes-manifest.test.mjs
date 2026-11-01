// SPDX-License-Identifier: AGPL-3.0-or-later
import assert from "node:assert/strict";
import { test } from "node:test";
import { toClaimPaths, webManifest } from "./routes-manifest.mjs";

test("SvelteKit ids become the gateway's patterns", () => {
  assert.deepEqual(toClaimPaths("/"), ["/"]);
  assert.deepEqual(toClaimPaths("/lists/[id]"), ["/lists/:id"]);
  assert.deepEqual(toClaimPaths("/@[acct]/followers"), ["/@:acct/followers"]);
  assert.deepEqual(toClaimPaths("/(app)/tags/[[tag]]"), ["/tags", "/tags/:tag"]);
  assert.deepEqual(toClaimPaths("/docs/[...rest]"), ["/docs/*"]);
});

test("the manifest claims the pages and the build's assets, and wants no cookie", () => {
  const m = webManifest(["/", "/@[acct]"]);
  assert.equal(m.name, "web-simple");
  assert.deepEqual(m.cookies, []);
  const paths = m.claims.map((c) => c.path);
  assert.ok(paths.includes("/@:acct"));
  assert.ok(paths.includes("/_app/*"));
  assert.ok(paths.every((p) => !p.split("/").some((s) => s.startsWith("."))));
});
