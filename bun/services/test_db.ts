// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Embedded Postgres for tests via PGlite (Postgres compiled to WASM),
// exposed over the Postgres wire protocol so Elixir's Postgrex can
// connect — no Docker / Postgres server required.
//
//   node --import tsx services/test_db.ts            # in-memory, 127.0.0.1:15432
//   PGLITE_PORT=15999 node --import tsx services/test_db.ts
//   PGLITE_DATA=./.pglite-test node --import tsx ...  # persist to a dir
//
// Caveats (see docs/TESTING.md): single database (PGlite has no
// CREATE DATABASE — the Repo connects with whatever DB name PGlite
// serves), SSL unsupported (Postgrex ssl: false), auth is trust-ish.
import { PGlite } from "@electric-sql/pglite";
import { PGLiteSocketServer } from "@electric-sql/pglite-socket";

const port = Number(process.env.PGLITE_PORT ?? "15432");
const host = process.env.PGLITE_HOST ?? "127.0.0.1";
const dataDir = process.env.PGLITE_DATA ?? "memory://";
// PGlite is single-connection; the socket server multiplexes several
// client connections over it. Ecto opens a pool (+ a migration-lock
// connection), so a single connection isn't enough — enable the muxer.
const maxConnections = Number(process.env.PGLITE_MAX_CONN ?? "20");

const db = await PGlite.create({ dataDir });
const server = new PGLiteSocketServer({ db, port, host, maxConnections });
await server.start();
console.log(`pglite-socket listening on ${host}:${port} (data=${dataDir})`);

const stop = async () => {
  await server.stop();
  await db.close();
  process.exit(0);
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
