# Datalevin store

The business data is kept in [Datalevin](https://github.com/juji-io/datalevin).
It is the only store: PostgreSQL holds the job queues (Oban) and the raw
bodies, and nothing else.

Read `docs/ARCHITECTURE.md` first. This page only covers what changes.

## What it is

- `SukhiFedi.Repo` still looks like an Ecto repo. Its adapter
  (`SukhiFedi.Store.Adapter`) hands each call to
  `SukhiFedi.Datalevin.Adapter`. Application code reads and writes it as it
  would Ecto.
- A Datalevin row is one entity; each column is an attribute
  `:"table/column"`. Types, defaults, unique indexes and foreign keys come
  from `elixir/priv/datalevin/catalog.exs`, which is edited by hand;
  a change to it goes with a migration (`DATALEVIN_MIGRATIONS.md`).
- The `dtlv` binary runs as a child of the BEAM over a pipe
  (`dtlv mcp -w`), one database, one writer. A reader never waits for the
  writer.
- Oban keeps its jobs in PostgreSQL (`DB_*`), one `oban_jobs` table for the
  gateway's and the delivery node's queues.

## Queries are Datalog, not SQL translated row by row

`from(...)` with joins is compiled into **one** Datalog query:

- a join is a shared variable (`[?e1 :notes/id ?j1] [?e0 :boosts/note_id ?j1]`),
- the rows come back already pulled (`(pull ?e0 [*])`),
- `order_by`, `limit` and `offset` run in the engine when the result is the
  same as SQL's (the columns are `NOT NULL`),
- `or` becomes `or-join`; `like`, `in`, `is_nil` become predicates.

Whatever the engine cannot say is re-checked in Elixir on the returned rows
(`SukhiFedi.Datalevin.Eval`). The whole `where` is always re-checked as a
backstop, so a compile slip cannot widen a result. A fragment that cannot be
evaluated at all raises `Eval.Unsupported` rather than answering wrong.

The home timeline and a profile's posts (boosts included) are several small
independent queries, not one SQL statement. In this mode they are sent
together: `Client.query_many/1` pipelines requests down the one pipe.

## Durability

`DATALEVIN_DURABILITY` is the choice that matters.

| Value | What a crash can lose | Use |
|---|---|---|
| `strict` | nothing acknowledged | default |
| `relaxed` | a short, bounded tail (group commit) | write-heavy, can accept it |
| `extra` | nothing; also macOS `F_FULLSYNC` | the same as strict on Linux |
| `lmdb` | nothing acknowledged, no log, slower writes | when the log is unwanted |
| `nosync` | possibly a lot | tests, throwaway data |

Whatever you pick, a transaction here is **not crash-atomic** (below).

## Recommended values for a 0.5 OCPU / 512 MB box

```
DATALEVIN_DURABILITY=strict
DATALEVIN_XMX=96m            # 64m works for light use; uncapped costs ~230 MB more
DATALEVIN_MAP_SIZE_MB=1024   # raise before the data approaches it
DATALEVIN_WAL_RETENTION_MB=256
DATALEVIN_WAL_RETENTION_HOURS=24
```

Measured on this machine (the cloud dev box; a slow disk will move the
durability rows): 500 single-row inserts, 500 reads by an unindexed-in-Ecto
`where name == ^x`, and 500 inserts in one transaction, one row at a time.

| `DATALEVIN_DURABILITY` | insert / row | read / row | in a transaction / row | `dtlv` RSS |
|---|---|---|---|---|
| `strict` | 2.9 ms | 1.1 ms | 3.1 ms | 259 MB |
| `relaxed` | 2.5 ms | 1.3 ms | 2.9 ms | 260 MB |
| `lmdb` | 3.1 ms | 1.4 ms | 3.5 ms | 254 MB |
| `nosync` | 2.2 ms | 1.3 ms | 2.7 ms | 254 MB |

The fsync is not what costs here: a row insert is a few round trips to
`dtlv` (unique check, sequence, the write), and that is about 2 ms whatever
the profile. So `strict` is the right default; `relaxed` buys little on a
fast disk. A slow or networked disk is where the profiles will differ; measure
there. (An earlier measurement: the `dtlv` process sat near 274 MB RSS with
`-Xmx64m` and near 507 MB uncapped.) It is a native image, so budget about
270 MB for it before the BEAM and everything else. On a 512 MB box that is
tight; Postgres on the same box is not cheaper, but it is more predictable.

## What does not work, or differs

Be careful with this list; it is the honest part.

- **Transactions.** `Repo.transaction` takes a writer lock and writes
  through with an undo log. Rollback works. A crash in the middle leaves the
  written part, and another reader can see uncommitted writes meanwhile.
- **Raw SQL** (`Repo.query!`) does not work, so the code that runs on both
  stores is written as Ecto queries. That is done for the pull federation,
  `SukhiShared.PullStats` and `SukhiShared.PeerCapabilities` (the shared
  library now depends on Ecto, which every node already has). The two
  repair tasks, `Maintenance.RebuildRemoteNotes` and
  `Maintenance.RebuildRemoteNoteIds`, are plain Ecto too.
- **Oban's tables are in PostgreSQL, not in `Repo`.** Code that reads `oban_jobs`
  goes through `SukhiFedi.Queue.repo/0` (the delivery status, the server
  activity page and the metrics do). Jobs are not in the same store as the
  business rows.
- **Constraints.** Unique indexes, `on_conflict`, defaults and
  `ON DELETE` are enforced by the writer. Foreign keys are not checked on
  insert; `NOT NULL` and check constraints are not enforced.
- **Postgres triggers** are not there. Tests that rely on them (admin audit
  rows) fail.
- **`lower()` unique keys** scan candidates, they are not index lookups.
- **Fragments.** Common ones (`lower`, `length`, JSON `->>`, `EXISTS (SELECT
  1 FROM t WHERE t.c = ?)`, a row comparison) run in Elixir; the rest raise
  `Unsupported`. `LIKE` is always checked in Elixir: dtlv 1.2.10's native
  image cannot run its own `like`.
- **Sort and limit on a nullable column** happen in memory.
- **Speed.** The integration suite is about 3 to 4 times slower per test than
  on PGlite so far. This is a first implementation, not a tuned one.
- Two `dtlv` 1.2.10 bugs are worked around in the compiler (the same
  attribute bound twice on one entity inside a join; `(= ?x false)`). Results
  are capped at 10000 items per request.

## Where the test suite stands

`make test-pgrust` (Datalevin for the data, pgrust for the job queues):
**970 passed, 12 skipped** (the skipped ones need S3 or NATS), plus the
delivery node's queue tests. `scripts/test-pgrust.sh` and `docs/TESTING.md`
say how to run it.

## The web client

The web client only speaks the Mastodon-style REST API, so it does not know
which store is behind it. Checked 2026-10-29, with the SPA then embedded in the
combined **prod** release (no NATS) and a real browser, once on Datalevin and once on
Postgres 16, same script, same answers: sign-up with the mailed code, post,
home / tag / profile / notifications / bookmarks / lists / settings pages,
follow, favourite, boost, bookmark, reply, DM, delete. The three requests
that fail on both stores are not store related: `/api/wt` (WebTransport is
not configured), `/api/i/notes/drafts` (404) and `PUT .../react/:emoji`.

## A new instance

Run the **combined** release (gateway, delivery and api in one BEAM) with a
PostgreSQL for the job queues (`DB_*`; `DB_USER` and `DB_PASS` are required).
Datalevin has one writer, so the delivery node cannot be a separate process; it
joins the store the gateway started (`SukhiDelivery.Store.Adapter`,
`owner?: false`).

    docker compose -f docker-compose.yml -f docker-compose.combined.yml \
                   -f docker-compose.datalevin.yml up -d

What the delivery half does:

What changes for the delivery half:

- **Queues.** `SukhiDelivery.Oban` runs the `delivery`, `federation`, `push`
  and `outbox_dispatch` queues on PostgreSQL, in the same `oban_jobs` table as
  the gateway's own queues (`SukhiFedi.Oban`); each node runs only the queues
  its config names.
- **Outbox relay.** It polls every 2 s (no `LISTEN/NOTIFY`, no row lock).
- **Pull Federation** (`pull_log`, `pull_heads`, `pull_peers`) uses plain
  statements (`SukhiDelivery.PullFederation.Peers`, `Log`), the same on both
  stores.
- **Migrations.** The schema is derived (`priv/datalevin/catalog.exs`)
  and a new attribute needs nothing. `migrate_all` runs the
  versioned Datalevin migrations for what that does not cover
  ([DATALEVIN_MIGRATIONS.md](DATALEVIN_MIGRATIONS.md)).
- **Image.** `dtlv` is only published as a glibc build and the runtime image is
  Alpine. `combined/Dockerfile` therefore gives `dtlv` its own glibc (loader and
  libm/libmvec/libgomp, copied from an Ubuntu stage) and `/usr/local/bin/dtlv`
  is a wrapper that runs the real binary through that loader. The release is
  picked per CPU (`TARGETARCH`), pinned by SHA-256: the amd64 build does not
  start on arm64, which is what production runs. `gcompat` alone is not enough:
  the arm64 build lacks `posix_fallocate64` there and, with that shimmed, still
  fails to load its JNI library ("Can't load library: jniDTLV"). Checked on an
  arm64 box: `dtlv mcp -w` opens a database from an Alpine container this way;
  the amd64 path is not exercised and none of this is covered by CI.

## Switching an existing instance

There is no conversion tool from the earlier PostgreSQL store yet. An existing
Datalevin store can be brought into a matching release by restoring the
complete `DATALEVIN_DIR` and the PostgreSQL
database that holds the job queues and `raw_blobs` (dump it yourself:
`Maintenance.Backup` does not cover it). If `SUKHI_RAW_BACKEND=s3`, restore the
configured raw bucket/prefix too.
Restore the mounted `/etc/sukhi/instance.json`, keep `DOMAIN` and signing
secrets stable, and stop the old writer before copying files.

On first successful open, the release writes
`DATALEVIN_DIR/.sukhi-store.json` with the
migrations the data has been through and the schema it was last opened with.
A schema that only gained attributes opens as it is; a removed or changed
attribute needs a migration, and without one startup is refused rather than
opening a store the code cannot read. A store without this file is accepted
once and stamped; the journal reports this
([DATALEVIN_MIGRATIONS.md](DATALEVIN_MIGRATIONS.md)).

Before a planned backup, create a non-secret inventory:

```sh
podman exec <gateway-container> /app/bin/combined eval \
  'SukhiFedi.Release.write_datalevin_backup_manifest!()'
```

The resulting `backup-manifest.json` lists the data directory,
queue files, raw backend, instance config path, catalog fingerprint and
migration version. It
does not contain secrets or copy any data.

After restoring those paths, validate the inventory before starting normal
traffic:

```sh
podman exec <gateway-container> /app/bin/combined eval \
  'SukhiFedi.Release.check_datalevin_backup_manifest!()'
```

The check refuses data from a newer release than this one (an older one is
migrated forward when it starts), mismatched data paths, or missing
queue directories. It does not test S3 credentials or perform a
Postgres import.
