// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Stamp the SPA build with when it was built.
//
// Two copies of this build can end up on a server at once: the one baked
// into the release, and the one an operator pushed onto the host with
// `make push-static`. Something has to decide which answers a request,
// and for a while that something was the files' mtime — which turned out
// to measure "last written to this disk", not "last built". DeployEx
// unpacks a release tarball on every deploy, so the baked copy was always
// stamped `now` and the pushed one could never win.
//
// So the build says so itself, and travels with its own answer: whatever
// copies `build/` — a Dockerfile, the on-box release build, an rsync —
// carries this file along without knowing about it.
//
// Runs as `postbuild`, so `npm run build` is all anyone has to remember.
import { writeFileSync } from "node:fs";
import { join } from "node:path";

const out = join(import.meta.dirname, "..", "build", ".static-build.json");
const now = new Date();

const manifest = {
  built_at: Math.floor(now.getTime() / 1000),
  built_at_iso: now.toISOString(),
  // Who made this copy. Informational — the server compares built_at —
  // but it is what tells you, from a response header, whether the thing
  // you are looking at came from a release or from your own push.
  source: process.env.SUKHI_STATIC_SOURCE || "build",
};

writeFileSync(out, JSON.stringify(manifest, null, 2) + "\n");
console.log(`static manifest: ${manifest.source} @ ${manifest.built_at_iso}`);
