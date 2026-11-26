# The store

The business data is kept in [hosigraph](https://github.com/sukhi-social/hosigraph) (an
append-only event log with Datalevin as its "now"), through the Ecto adapter
[`ecto_hosi`](https://github.com/sukhi-social/hosigraph/tree/main/ecto_hosi). PostgreSQL holds the job queues (Oban),
the outbox, accounts (`AccountRepo`) and raw blobs, and nothing else.

Read `ARCHITECTURE.md` first. This page covers what the store changes.

## What it is

- `SukhiFedi.Repo` is an ordinary Ecto repo. Its adapter (`SukhiFedi.Store.Adapter`) hands every
  call to `Ecto.Adapters.Hosi`. Code reads and writes it as it would Ecto.
- A row is one entity; each column is an attribute `:"table/column"`. The id is the entity id,
  assigned by hosigraph at write time (it sorts by time). **An insert cannot choose its id.**
- The schema is derived from the Ecto schemas under `SukhiFedi.Schema` when the Repo opens
  (`SukhiFedi.Store.Hosi.schemas/0`). A new column or table needs no migration.
- The rules PostgreSQL kept are declared on the schemas and kept by the adapter:
  `hosi_unique` (unique indexes, composites, `lower`, partial), `hosi_ref` (`ON DELETE`
  cascade / nilify / restrict), `hosi_append_only` (`admin_audits`), `hosi_tuple` (the
  `(account_id, created_at)` index the timelines walk with `Repo.highest_in/5`). See
  `ecto_hosi`'s README for each.
- The delivery node's repo (`SukhiDelivery.Repo`) joins the gateway's (`join: SukhiFedi.Repo`):
  one store, one set of rules, in one BEAM (the combined release).

## What differs from SQL

- **Transactions.** `Repo.transaction` writes at once and undoes on rollback; other readers see
  the writes meanwhile, and a crash in the middle keeps them. A `Multi` of known changesets and
  `Repo.write_batch/2` are one atomic write.
- **Queries** are compiled to Datalog where Datalog can say them, and finished in Elixir where it
  cannot. No UNION and no subquery in `from` or `where`: read in steps and pass `in ^ids`
  (`Timelines`, `Deco.Posts` do).
- **Raw SQL** (`Repo.query!`) does not exist; write Ecto, or `Repo.datalog/1`.
- **Oban's tables are in PostgreSQL**, not in `Repo`: code that reads `oban_jobs` goes through
  `SukhiFedi.Queue.repo/0`. A job is never in the same store as the row that caused it.
- **No SQL triggers or `NOT NULL`/check constraints.**

## Configuration

`SukhiFedi.Store.Config` reads the environment. Today the store uses `DATALEVIN_DIR` (hosigraph
keeps its files in `<dir>/ecto_hosi`) and `DATALEVIN_BIN` (the `dtlv` it runs; `HOSI_JAR` runs
the standalone jar on a JVM instead). The durability and size knobs (`DATALEVIN_DURABILITY`,
`DATALEVIN_XMX`, ...) are still parsed but **not yet handed to hosigraph**.

## A new instance

Run the combined release with PostgreSQL for the job queues (`DB_*`) and a directory for
`DATALEVIN_DIR`. `combined/Dockerfile` gives `dtlv` its own glibc. Both release images
(`combined/Dockerfile`, `elixir/Dockerfile`) build libhosi from the hosigraph commit that
`elixir/mix.lock` pins for `hosi` (`elixir/rel/build-libhosi-alpine.sh`, in a stage of its own), because
hosigraph has no prebuilt release for that commit; they carry it at `/opt/libhosi`. That stage is the
slow part of a cold build and reruns only when the pinned commit moves. The gateway image has no `dtlv`
or JVM, so it cannot open the store by itself.

## Switching an existing instance

There is no conversion from the earlier Datalevin or PostgreSQL stores: the data is not carried
over. For a new store, take a backup (`Maintenance.Backup`, which copies `DATALEVIN_DIR` with
`dtlv copy`; the PostgreSQL side is dumped separately), and write the inventory:

```sh
podman exec <gateway-container> /app/bin/combined eval 'SukhiFedi.Release.write_backup_manifest!()'
# after restoring the paths:
podman exec <gateway-container> /app/bin/combined eval 'SukhiFedi.Release.check_backup_manifest!()'
```

The check refuses a mismatched data directory or raw backend. It tests no credentials.
