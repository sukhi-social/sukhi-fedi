# Testing

Two ways to run the Elixir integration suite. Pick by what the tests touch.

## Quick: PGlite (no Docker)

For the large class of tests that only need **Postgres**, run against an
embedded [PGlite](https://pglite.dev) (Postgres compiled to WASM) exposed
over the wire protocol — no Docker daemon, no Postgres server:

```bash
make test-pglite
make test-pglite ARGS="test/integration/social_test.exs:97"
# or directly, with mix-test args passed through:
scripts/test-pglite.sh test/integration/social_test.exs
```

The script starts `bun run bun/services/test_db.ts` (an in-memory PGlite
on `127.0.0.1:15433`), runs `mix sukhi.migrate`, then `mix test --only
integration`, and stops PGlite on exit.

**What it covers:** every test that only needs Postgres.

**What it does NOT:** tests that need NATS (streaming) or S3 (media,
inbound_archive); those tests carry `skip: s3_skip()` and the script
sets `SKIP_S3_TESTS=1`, so they show as skipped. The script sets `DISABLE_ADDONS=streaming` so the app
boots without NATS — streaming integration tests are skipped on this
path. For those, use the Docker route below.

### Caveats (why the config bends a little)

PGlite is a *single* Postgres instance, multiplexed over one connection
by `pglite-socket`. So:

- **One database.** PGlite has no `CREATE DATABASE`; it serves a single
  DB and ignores the requested name. The Repo's `database:` is therefore
  irrelevant on this path (no `ecto.create` needed — `sukhi.migrate`
  runs straight against it).
- **Small pool.** `config/test.exs` reads `DB_POOL_SIZE` (the script
  sets `5`); the socket server runs with `maxConnections=20`.
- **Migration lock off.** The lock holds a second connection for the
  whole run and deadlocks against the migrating connection on the
  multiplexer, so `config/test.exs` sets `migration_lock: false`. A
  single test migrator never races, so the lock isn't needed.
- **No SSL.** Postgrex connects with `ssl: false` (the default).
- **Unnamed prepared statements.** PGlite's multiplexer mishandles
  *named* prepares (a reused plan with a different param count throws
  `08P01 protocol_violation`), so `config/test.exs` sets
  `prepare: :unnamed`. Harmless on real Postgres.

`config/test.exs` takes `DB_HOST` / `DB_PORT` / `DB_USER` /
`DB_PASSWORD` / `DB_NAME` / `DB_POOL_SIZE` from the environment, with
defaults (`127.0.0.1` / `15432` / `postgres` / `postgres`) that match
**both** the Docker Postgres and PGlite.

## Full: Docker Compose

For the whole suite — including streaming (NATS), media + inbound_archive
(S3/rustfs), and the Bun fedify service — bring up the stack:

```bash
docker compose -f docker-compose.test.yml up -d
cd elixir && MIX_ENV=test mix sukhi.migrate
mix test --only integration
```

`docker-compose.test.yml` provides Postgres (`15432`), NATS (`14222`),
rustfs (S3) and the Bun fedify NATS Micro service.
