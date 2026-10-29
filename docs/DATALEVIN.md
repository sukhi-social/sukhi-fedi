# Datalevin store

`SUKHI_STORE=datalevin` keeps the business data in
[Datalevin](https://github.com/juji-io/datalevin) instead of Postgres.
Postgres stays the default and the path the rest of the docs describe.
This one is switched by an environment variable at start; no rebuild.

Read `docs/ARCHITECTURE.md` first. This page only covers what changes.

## What it is

- `SukhiFedi.Repo` still looks like an Ecto repo. Its adapter
  (`SukhiFedi.Store.Adapter`) hands each call to Postgres or to
  `SukhiFedi.Datalevin.Adapter`, chosen once at boot. Application code does
  not know which.
- A Datalevin row is one entity; each column is an attribute
  `:"table/column"`. Types, defaults, unique indexes and foreign keys come
  from `elixir/priv/datalevin/catalog.exs`, a snapshot of the migrated
  Postgres schema. Regenerate it after a migration:
  `mix sukhi.datalevin.catalog` (needs a migrated Postgres).
- The `dtlv` binary runs as a child of the BEAM over a pipe
  (`dtlv mcp -w`), one database, one writer. A reader never waits for the
  writer.
- Oban keeps its jobs in SQLite (`SUKHI_QUEUE_DB`) in this mode, the same
  engine the delivery service already uses.

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
SUKHI_STORE=datalevin
DATALEVIN_DURABILITY=strict
DATALEVIN_XMX=96m            # 64m works for light use; uncapped costs ~230 MB more
DATALEVIN_MAP_SIZE_MB=1024   # raise before the data approaches it
DATALEVIN_WAL_RETENTION_MB=256
DATALEVIN_WAL_RETENTION_HOURS=24
SUKHI_QUEUE_SYNCHRONOUS=normal   # if losing the last job insert on power loss is fine
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
- **Raw SQL** (`Repo.query!`) does not work. The sites are the pull
  federation (`PullFederation.*`), `Maintenance.RebuildRemoteNotes*`, and
  the `mix sukhi.datalevin.catalog` task (which is meant for Postgres). They
  need a port to Ecto queries first. On this branch the pull federation
  therefore does not run on Datalevin.
- **Oban's tables are in SQLite, not in `Repo`.** Tests and tools that look at
  `oban_jobs` through `Repo` (a few of them: DeliveryStatus, QuoteFederation,
  WebPush) see nothing; go through `SukhiFedi.QueueRepo`.
- **Constraints.** Unique indexes, `on_conflict`, defaults and
  `ON DELETE` are enforced by the writer. Foreign keys are not checked on
  insert; `NOT NULL` and check constraints are not enforced.
- **Postgres triggers** are not there. Tests that rely on them (admin audit
  rows) fail.
- **`lower()` unique keys** scan candidates, they are not index lookups.
- **Fragments.** `ILIKE` and other fragments run in Elixir, or raise
  `Unsupported`. Example: a home timeline for a viewer who owns a list with a
  keyword filter uses such a fragment and is not supported yet; everyone
  else is unaffected.
- **Sort and limit on a nullable column** happen in memory.
- **Speed.** The integration suite is about 3 to 4 times slower per test than
  on PGlite so far. This is a first implementation, not a tuned one.
- Two `dtlv` 1.2.10 bugs are worked around in the compiler (the same
  attribute bound twice on one entity inside a join; `(= ?x false)`). Results
  are capped at 10000 items per request.

## Where the test suite stands

`SUKHI_STORE=datalevin mix test --only integration`: **774 of 839 pass**
(Postgres: 836; the 3 that fail there fail here too). About 2.5 minutes.
The 65 that do not:

| Count | Why |
|---|---|
| 50 | raw SQL in the pull federation, rebuild tasks, PeerCapabilities |
| 5 | the test reads Oban jobs through `Repo` (jobs are in SQLite here) |
| 2 | Postgres triggers (admin audits are append-only by trigger) |
| 2 | home timeline for a viewer with a keyword list (fragment) |
| 3 + 1 + 2 | pages that also fail on Postgres main (`/licenses`, `/credits`, a map), and one `Relays` case |

## Switching an existing instance

There is no data migration tool yet. Starting with `SUKHI_STORE=datalevin`
on an existing instance starts from an empty database.
