// SPDX-License-Identifier: AGPL-3.0-or-later
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { createWebSimple } from "./server.mjs";

let server, base;

before(async () => {
  const dir = mkdtempSync(join(tmpdir(), "web-simple-"));
  mkdirSync(join(dir, "_app/immutable"), { recursive: true });
  mkdirSync(join(dir, ".sukhi"), { recursive: true });
  writeFileSync(join(dir, "index.html"), "<!doctype html><title>shell</title>");
  writeFileSync(join(dir, "_app/immutable/a.js"), "export {}");
  writeFileSync(join(dir, ".sukhi/web.json"), '{"name":"web-simple","claims":[],"cookies":[]}');
  server = createWebSimple(dir);
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

test("a page path is the shell, never cached", async () => {
  const res = await fetch(`${base}/lists/42`);
  assert.equal(res.status, 200);
  assert.match(await res.text(), /shell/);
  assert.match(res.headers.get("cache-control"), /no-cache/);
});

test("a hashed chunk is cache-forever", async () => {
  const res = await fetch(`${base}/_app/immutable/a.js`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get("cache-control"), /immutable/);
  assert.match(res.headers.get("content-type"), /javascript/);
});

test("the manifest for the gateway is served", async () => {
  const res = await fetch(`${base}/.sukhi/web.json`);
  assert.equal((await res.json()).name, "web-simple");
});

test("nothing outside the build is reachable", async () => {
  const res = await fetch(`${base}/..%2f..%2fetc/passwd`);
  assert.match(await res.text(), /shell/);
});

test("only GET and HEAD", async () => {
  const res = await fetch(`${base}/x`, { method: "POST" });
  assert.equal(res.status, 405);
});
