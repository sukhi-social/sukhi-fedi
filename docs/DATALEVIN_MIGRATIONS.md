<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Datalevin migrations

> **Intent:** change what is stored in a Datalevin store without losing it,
> and say plainly when a change needs more than a restart.
> **Reader's problem (hypothesis):** "I changed a column, or I am upgrading
> a server. Will the data still open? What do I have to do?"

Applies to `SUKHI_STORE=datalevin`. Postgres keeps its own migrations
(`priv/repo/migrations`).

## What happens on an upgrade

The container entrypoint runs `Release.migrate_all/0` before anything serves.
With Datalevin that is `SukhiFedi.Datalevin.Migrator`, once for the main store
(`DATALEVIN_DIR`) and once for the graph store (`DATALEVIN_DIR/graph`, with
`SUKHI_GRAPH=1`). Each store keeps `.sukhi-store.json` beside its data: the
migrations it has been through, and the schema it was last opened with.

| The store is… | What the release does |
| --- | --- |
| a new, empty directory | creates it with the current schema; records every migration as already applied |
| from before migrations existed (no manifest, or the old one) | takes it as it stands, stamps it, runs every migration (they are safe to repeat) |
| only different by **new attributes** | opens it. Nothing to write; old rows read the new attribute as empty |
| different by a **removed or changed attribute** and a migration is waiting | copies the directory, runs the migrations oldest first, opens with the new schema, stamps |
| different that way and **no migration** | refuses, and says which attributes |
| carrying a migration this release does not know (a newer release wrote it) | refuses: start that release or restore a backup from before it |

Before the first migration of a run, the store's files are copied to
`datalevin-premigrate/<store>-<time>-before-<version>/` beside `DATALEVIN_DIR`
(`DATALEVIN_PREMIGRATE_BACKUP=0` turns it off, `DATALEVIN_PREMIGRATE_DIR` moves
it). Nothing deletes these; remove them once the new version has settled.
Needs room for a second copy of the data.

The application itself refuses to start on a store with a migration pending
or data from a newer release, so skipping the entrypoint cannot open one
half-migrated.

If a migration stops partway (power loss, a failed request), the manifest
says which one (`"migrating"`), and the next start runs it again from the
beginning. That is why they must be safe to repeat.

```sh
# Where does each store stand? Changes nothing.
bin/sukhi_fedi eval 'SukhiFedi.Release.datalevin_migration_status()'
```

## Running it by hand (short guide)

The entrypoint already does this on every start. Do it by hand when you want
to watch it, or to migrate before switching traffic over.

1. **Stop the app.** Datalevin has one writer; nothing else may have the
   store open.
2. **Look.** Nothing is changed by this:
   ```sh
   podman exec <gateway-container> /app/bin/combined eval \
     'SukhiFedi.Release.datalevin_migration_status()'
   ```
   `state=pending` lists the versions that will run. `state=error` says why
   it will not (newer data, a missing migration).
3. **Back up** the whole `DATALEVIN_DIR` (including `graph/`). The migrator
   copies it too, but a copy you made yourself is the one you chose.
4. **Run:**
   ```sh
   podman exec <gateway-container> /app/bin/combined eval \
     'SukhiFedi.Release.migrate_all()'
   ```
   It prints `datalevin_migration_start` / `_done` for each one, and ends with
   `store_init_complete`.
5. **Look again** (step 2). It should say `state=current`.
6. **Start the app.**

If step 4 fails, read the message, fix the cause, and run step 4 again; a
migration that stopped midway starts over from its beginning. To go back
instead, stop the app, put the copy from step 3 (or from
`datalevin-premigrate/`) back, and start the previous release.

## Writing a migration

You need one only when the schema loses or changes an attribute, or old rows
need a value the new code expects. A new column needs none.

```sh
mix sukhi.datalevin.gen.migration drop_old_flag            # main store
mix sukhi.datalevin.gen.migration backfill_sid --store graph
```

That writes `lib/sukhi_fedi/datalevin/migrations/v<time>_<name>.ex`:

```elixir
defmodule SukhiFedi.Datalevin.Migrations.V20261105100000DropOldFlag do
  use SukhiFedi.Datalevin.Migration, version: 20261105100000, store: :main

  # The attribute is gone from the current schema; say how it was defined so
  # the migration can still read it.
  @impl true
  def schema, do: %{":accounts/old_flag" => %{":db/valueType" => ":db.type/boolean"}}

  @impl true
  def up(ctx) do
    Ops.backfill!(ctx, :"accounts/id", :"accounts/locked", false)
    Ops.retract_attr!(ctx, :"accounts/old_flag")
    :ok
  end
end
```

`Ops` (in `SukhiFedi.Datalevin.Migration.Ops`):

| Call | Does |
| --- | --- |
| `backfill!(ctx, anchor, attr, value)` | gives `attr` the value on every entity that has `anchor` and lacks `attr` |
| `rename_attr!(ctx, old, new)` | copies every value to `new`, then removes `old` (many-valued attributes included) |
| `retract_attr!(ctx, attr)` | removes `attr` from every entity |
| `drop_entities!(ctx, anchor)` | removes every entity that has `anchor` (a dropped table) |
| `query!/2`, `transact!/2` | raw Datalog, for what the above do not cover |

Rules:

- **Safe to repeat.** `Ops` only does what is still left to do. If you write
  your own `transact!`, make a second run change nothing.
- **Old shape while it runs.** The store is open with the schema it had
  before, plus the new attributes. Put what the current schema no longer
  defines in `schema/0`.
- **One time order.** Versions are UTC timestamps; one older than an applied
  one is refused, as Postgres does. Rename it.
- **Never edit a shipped one.** Stores that ran it do not run it again; write
  a new one.
- Keep batches small: `Ops` writes `DATALEVIN_BATCH` entities per transaction
  and walks in slices, so a large table is not read into memory at once.

## The lock: catching it in the pull request

`priv/datalevin/schema.lock.json` is the schema of both stores as the last
change left it (one attribute per line, so the diff reads as the change), plus
the newest migration's version.

```sh
mix sukhi.datalevin.catalog   # after SQL migrations, as before
mix sukhi.datalevin.lock      # record it
```

- A **new attribute** is recorded as is.
- A **removed or changed attribute** is refused until a migration newer than
  the lock exists. The error names the attributes and the command.
- `mix test` fails when the lock is stale (`schema_lock_test.exs`), so the
  schema cannot move without the lock moving with it.

## What this does not do

- It does not convert Postgres to Datalevin (`DATALEVIN.md`, "Switching an
  existing instance").
- It cannot undo: going back means restoring the copy in
  `datalevin-premigrate/` or a backup, then starting the older release.
- It does not copy the SQLite queues or the raw store; only the Datalevin
  directory it migrates.
- The manifest is a file beside the data, not a record inside it. Restore a
  directory whole; a `data.mdb` copied alone has no history, and is taken as
  a store from before migrations existed (every migration runs, harmlessly).
