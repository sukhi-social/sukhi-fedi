#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Run the Elixir integration suite: the business data in a throwaway Datalevin
# directory (needs `dtlv`), the job queues on a throwaway pgrust server (a
# PostgreSQL-compatible server that is one binary; scripts/lib/pgrust.sh
# fetches it the first time) — no Docker / Postgres install.
#
#   scripts/test-pgrust.sh                          # all DB-only integration tests
#   scripts/test-pgrust.sh test/integration/social_test.exs
#   scripts/test-pgrust.sh test/integration/social_test.exs:97
#
# Extra args are passed straight to `mix test` (and then only the gateway's
# suite runs; the delivery node's queue tests run with the whole suite).
#
# What this DOES cover: every test that needs only Datalevin and the job
# queues. pgrust replaces the docker-compose Postgres entirely.
#
# What it does NOT: tests that need NATS (streaming) or S3 (media,
# inbound_archive). The streaming addon is disabled here so the app can
# boot without NATS; for those tests bring up docker-compose.test.yml.
#
# PGRUST_PORT (default 15433) picks the port; PGRUST_DIR uses a pgrust you
# already have. See docs/TESTING.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PGRUST_PORT:-15433}"

export DB_PORT="$PORT"
export DISABLE_ADDONS="${DISABLE_ADDONS:-streaming}"
# Tests that write to S3 skip themselves (see s3_skip/0 in integration_case.ex).
export SKIP_S3_TESTS=1
export MIX_ENV=test

# The store: a fresh Datalevin directory per run, without fsync (a test
# directory is thrown away; durability is not what is under test).
command -v "${DATALEVIN_BIN:-dtlv}" >/dev/null || [ -n "${HOSI_JAR:-}" ] || {
  echo "dtlv not found: the business data is in Datalevin, so every integration test needs it." >&2
  echo "Install it (see .github/workflows/test.yml) or point DATALEVIN_BIN at it." >&2
  exit 1
}
DATALEVIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sukhi-datalevin-XXXXXX")"
export DATALEVIN_DIR
export DATALEVIN_DURABILITY=nosync

# shellcheck source=lib/pgrust.sh
. "$ROOT/scripts/lib/pgrust.sh"
pgrust_install

PGRUST_DATA="$(mktemp -d "${TMPDIR:-/tmp}/sukhi-pgrust-XXXXXX")"
trap 'pgrust_stop; rm -rf "$DATALEVIN_DIR" "$PGRUST_DATA"' EXIT

echo "→ starting pgrust on 127.0.0.1:$PORT (throwaway data directory)"
pgrust_initdb "$PGRUST_DATA"
pgrust_start "$PGRUST_DATA" "$PORT" "$PGRUST_DATA/server.log"
# config/test.exs asks for this name unless DB_NAME says otherwise.
pgrust_createdb "$PORT" "${DB_NAME:-sukhi_fedi_test}"

cd "$ROOT/elixir"
# Unreachable clauses / dead matches surface as compiler warnings —
# fail here, loudly, instead of scrolling past. See docs/CODE_STYLE.md §8.
echo "→ compiling (warnings are errors)"
mix compile --warnings-as-errors
echo "→ opening the store"
mix sukhi.migrate
echo "→ running tests"
mix test --only integration "$@"

# The delivery node's job-queue tests, on the same pgrust. With arguments the
# caller picked what to run, so leave them be.
if [ "$#" -eq 0 ]; then
  echo "→ delivery: queue tests"
  cd "$ROOT/delivery"
  # --no-start: the delivery app alone cannot start its store (the Datalevin
  # adapter is the gateway's); these tests start what they need themselves.
  mix test --no-start --only integration test/queue
fi
