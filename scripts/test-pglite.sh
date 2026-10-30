#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Run the Elixir integration suite against an embedded PGlite Postgres
# (Postgres-in-WASM over the wire protocol) — no Docker / Postgres server.
#
#   scripts/test-pglite.sh                          # all DB-only integration tests
#   scripts/test-pglite.sh test/integration/social_test.exs
#   scripts/test-pglite.sh test/integration/social_test.exs:97
#
# Extra args are passed straight to `mix test`.
#
# What this DOES cover: every test that only needs Postgres. PGlite
# replaces the docker-compose Postgres entirely.
#
# What it does NOT: tests that need NATS (streaming) or S3 (media,
# inbound_archive). The streaming addon is disabled here so the app can
# boot without NATS; for those tests bring up docker-compose.test.yml.
#
# Caveats baked in: PGlite serves a single database multiplexed over one
# connection, so the Repo runs with a small pool and the migration lock
# is off (config/test.exs reads DB_* env). See docs/TESTING.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PGLITE_PORT:-15433}"

export DB_PORT="$PORT"
export DB_POOL_SIZE="${DB_POOL_SIZE:-5}"
export DISABLE_ADDONS="${DISABLE_ADDONS:-streaming}"
# Tests that write to S3 skip themselves (see s3_skip/0 in integration_case.ex).
export SKIP_S3_TESTS=1
export MIX_ENV=test

echo "→ starting PGlite on 127.0.0.1:$PORT (in-memory)"
# bun's `run` used to fetch missing packages by itself; node does not.
[ -d "$ROOT/bun/node_modules" ] || (cd "$ROOT/bun" && pnpm install)
# `exec` replaces the subshell with node so $! is node's own PID — without
# it the trap would kill the subshell and orphan node, leaking the port.
( cd "$ROOT/bun" && PGLITE_PORT="$PORT" exec node --import @oxc-node/core/register services/test_db.ts ) &
PGLITE_PID=$!
trap 'kill "$PGLITE_PID" 2>/dev/null || true' EXIT

# Wait for the socket to accept connections.
for _ in $(seq 1 100); do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
  sleep 0.1
done

cd "$ROOT/elixir"
# Unreachable clauses / dead matches surface as compiler warnings —
# fail here, loudly, instead of scrolling past. See docs/CODE_STYLE.md §8.
echo "→ compiling (warnings are errors)"
mix compile --warnings-as-errors
echo "→ migrating"
mix sukhi.migrate
echo "→ running tests"
# Without dtlv the graph tests cannot run. CI installs it; elsewhere the
# `--exclude dtlv` below is only a courtesy and does not hold against
# `--only integration` (an include wins over an exclude for a test carrying
# both tags), so install dtlv or name the files to run.
skip=()
command -v "${DATALEVIN_BIN:-dtlv}" >/dev/null || skip=(--exclude dtlv)
mix test --only integration "${skip[@]}" "$@"
