// SPDX-License-Identifier: AGPL-3.0-or-later
//
// web-simple's server: the SPA build, and nothing else.
//
// The gateway sits in front (it is the only thing a browser reaches) and
// forwards the paths this build's `/.sukhi/web.json` claims. So this server
// has no routing of its own beyond "a file that exists, or the shell":
// the claims are what keep a non-page from ever arriving here.
//
//   PORT       (default 3000)
//   BUILD_DIR  (default ./build)
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, resolve, sep } from "node:path";

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".webp": "image/webp",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".webmanifest": "application/manifest+json",
  ".txt": "text/plain; charset=utf-8",
  ".map": "application/json",
};

/** The file under `root` that `pathname` names, or null (also for `..`). */
function locate(root, pathname) {
  let rel;
  try {
    rel = decodeURIComponent(pathname);
  } catch {
    return null;
  }
  const full = normalize(join(root, rel));
  return full === root || full.startsWith(root + sep) ? full : null;
}

async function fileOf(full) {
  const st = await stat(full).catch(() => null);
  return st?.isFile() ? st : null;
}

export function createWebSimple(buildDir = process.env.BUILD_DIR ?? "build") {
  const root = resolve(buildDir);

  return createServer(async (req, res) => {
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.writeHead(405, { allow: "GET, HEAD" }).end();
      return;
    }
    const { pathname } = new URL(req.url ?? "/", "http://localhost");

    let full = locate(root, pathname);
    let st = full && (await fileOf(full));
    // Not a file: the shell. (The gateway only sends claimed paths.)
    if (!st) {
      full = join(root, "index.html");
      st = await fileOf(full);
    }
    if (!st) {
      res.writeHead(503, { "content-type": "text/plain; charset=utf-8" }).end("not built");
      return;
    }

    // Content-hashed chunks never change; everything else (the shell, the
    // manifest) must be asked about every time — a CDN holding an old
    // index.html would name chunks that no longer exist.
    const immutable = pathname.startsWith("/_app/immutable/");
    const headers = {
      "content-type": MIME[extname(full)] ?? "application/octet-stream",
      "content-length": String(st.size),
      "cache-control": immutable ? "public, max-age=31536000, immutable" : "no-cache, must-revalidate",
    };
    res.writeHead(200, headers);
    if (req.method === "HEAD") res.end();
    else createReadStream(full).pipe(res);
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT ?? 3000);
  createWebSimple().listen(port, "0.0.0.0", () => console.log(`web-simple on :${port}`));
}
