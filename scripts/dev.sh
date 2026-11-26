#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# One command to have sukhi-fedi running locally, with no Docker.
#
#   make dev            (or: scripts/dev.sh)
#
# Brings up, in this order:
#
#   1. pgrust — a PostgreSQL-compatible server that is one binary (the same
#      one scripts/test-pgrust.sh uses for tests; scripts/lib/pgrust.sh
#      fetches it the first time). Its data is kept in .pgrust-dev/, so the
#      job queues survive a restart. Delete that directory to start empty.
#   2. The business data is a Datalevin directory (.datalevin-dev/, needs
#      `dtlv` on your PATH; the job queues are the pgrust above).
#   3. nats-server (plain core), *if* it is on your PATH.
#      Without them the app still runs — streaming and outbound
#      federation are simply off, and you are told so.
#   4. The combined release's projects (gateway + delivery + api in one
#      BEAM) on http://localhost:4000, with an IEx shell.
#
# The web client's dev server is a separate process on purpose — two programs
# writing to one terminal is worse than two terminals:
#
#   cd web-next && pnpm run dev    # http://localhost:5174, points at :4000
#
# Ports are picked to not collide with a docker-compose stack or with
# `make test-pgrust` (15433).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGRUST_PORT="${PGRUST_PORT:-15434}"
PGRUST_DATA="${PGRUST_DATA:-$ROOT/.pgrust-dev}"
export DATALEVIN_DIR="${DATALEVIN_DIR:-$ROOT/.datalevin-dev}"
NATS_PORT="${NATS_PORT:-14223}"

# shellcheck source=lib/pgrust.sh
. "$ROOT/scripts/lib/pgrust.sh"

# Shutting down is not instant: pgrust writes out what it holds before it
# exits (pgrust_stop waits for it), so the prompt can take a moment to come
# back after you leave IEx. That is the flush, not a hang.
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  pgrust_stop
}
# INT/TERM too: an untrapped signal would kill this shell without ever
# running the EXIT trap, orphaning pgrust and nats-server on the ports.
trap cleanup EXIT INT TERM

wait_for_port() {
  local port="$1" what="$2"
  for _ in $(seq 1 150); do
    nc -z 127.0.0.1 "$port" 2>/dev/null && return 0
    sleep 0.2
  done
  echo "→ $what did not come up on :$port" >&2
  return 1
}

command -v "${DATALEVIN_BIN:-dtlv}" >/dev/null 2>&1 || {
  echo "→ dtlv is needed for the store (the business data is in Datalevin); see .github/workflows/test.yml" >&2
  exit 1
}
pgrust_install

# The cluster is made once and kept; the database in it is made if missing.
[ -f "$PGRUST_DATA/PG_VERSION" ] || {
  mkdir -p "$PGRUST_DATA"
  pgrust_initdb "$PGRUST_DATA"
}
echo "→ pgrust on 127.0.0.1:$PGRUST_PORT  (data: ${PGRUST_DATA#"$ROOT"/})"
pgrust_start "$PGRUST_DATA" "$PGRUST_PORT" "$PGRUST_DATA/server.log"
pgrust_createdb "$PGRUST_PORT" sukhi_fedi_dev

# NATS carries the `stream.*` streaming subjects and the `fedify.*`
# request/reply the delivery side signs through. Both are optional for
# working on the UI or the REST surface, so a missing nats-server is a
# notice, not an error. Plain core NATS — nothing to bootstrap, since the
# outbox relay hands rows to Oban rather than to a stream.
if command -v nats-server >/dev/null 2>&1; then
  echo "→ nats-server on 127.0.0.1:$NATS_PORT"
  nats-server --port "$NATS_PORT" >/dev/null 2>&1 &
  pids+=("$!")
  wait_for_port "$NATS_PORT" "nats-server"
else
  echo "→ no nats-server on PATH — streaming and outbound signing are off"
  echo "  (brew install nats-server)"
fi

# Without NATS the streaming addon just logs that it can't connect.

export DB_PORT="$PGRUST_PORT"
export NATS_PORT

cd "$ROOT/combined"
echo "→ opening the store"
mix sukhi.migrate

echo "→ http://localhost:4000   (web client: \`pnpm run dev\` in web-next/, in another terminal)"

# Deliberately not `exec`: that would replace this shell, and the EXIT
# trap above would never run — leaving pgrust and nats-server holding
# their ports after every session.
iex -S mix
