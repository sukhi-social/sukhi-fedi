# Testing

Two ways to run the Elixir integration suite. Pick by what the tests touch.

## Quick: pgrust (no Docker)

The business data is in Datalevin and the job queues are in Postgres. The
script gives the first a throwaway directory (**`dtlv` must be on the PATH**,
or `DATALEVIN_BIN` must point at it) and the second a
[pgrust](https://pgrust.com) server, a PostgreSQL 18 compatible server that
needs no install — no Docker daemon, no Postgres server:

```bash
make test-pgrust
make test-pgrust ARGS="test/integration/social_test.exs:97"
# or directly, with mix-test args passed through:
scripts/test-pgrust.sh test/integration/social_test.exs
```

The first run fetches pgrust (about 30 MB, from pgrust.com) into `.pgrust/` and
checks it against the checksum pinned in `scripts/lib/pgrust.sh`; after that
it is local. `PGRUST_DIR` points at a pgrust you installed yourself, and
`PGRUST_PORT` moves it off `15433`.

The script starts pgrust on `127.0.0.1:15433` over a throwaway data directory,
creates `sukhi_fedi_test`, runs `mix sukhi.migrate` (Datalevin) against a fresh
`DATALEVIN_DIR`, then `mix test --only integration`, and with no arguments the
delivery node's queue tests (`delivery/test/queue`, `--no-start`), and stops
pgrust and removes both directories on exit. The delivery node's other
integration test (`pull_federation/origin_test.exs`) needs the gateway's store
in the same BEAM, so it is not run here.

**What it covers:** every test that needs only Datalevin and the job queues.

**What it does NOT:** tests that need NATS (streaming) or S3 (media,
inbound_archive); those tests carry `skip: s3_skip()` and the script
sets `SKIP_S3_TESTS=1`, so they show as skipped. The script sets `DISABLE_ADDONS=streaming` so the app
boots without NATS — streaming integration tests are skipped on this
path. For those, use the Docker route below.

### Notes

pgrust speaks the ordinary protocol, so `config/test.exs` has nothing special
for it: a pool of ten, named prepared statements and the migration lock are
as on any PostgreSQL. What is particular to it is in `scripts/lib/pgrust.sh`:
it wants a bigger stack than a shell gives (the script raises the limit and
sets `RUST_MIN_STACK`), and its Unix socket lives under `/tmp` because
macOS's `$TMPDIR` is too long for a socket path.

- It is a beta (v0.4-beta), and builds exist for Linux and macOS (x86-64 and
  Arm), not Windows. When a test fails here, running it on the Docker route
  below tells a pgrust difference from a bug.
- It is AGPL-3.0, a tool run beside the tests, not something sukhi ships.

`config/test.exs` takes `DB_HOST` / `DB_PORT` / `DB_USER` /
`DB_PASSWORD` / `DB_NAME` / `DB_POOL_SIZE` from the environment, with
defaults (`127.0.0.1` / `15432` / `postgres` / `postgres`) that match
**both** the Docker Postgres and pgrust (which trusts local connections).

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
