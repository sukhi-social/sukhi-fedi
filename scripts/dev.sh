#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# One command to have sukhi-fedi running locally, with no Docker.
#
#   make dev            (or: scripts/dev.sh)
#
# Brings up, in this order:
#
#   1. PGlite — Postgres compiled to WASM, served over the wire protocol
#      by bun (the same thing scripts/test-pglite.sh uses for tests).
#      Persisted in .pglite-dev/, so your accounts and posts survive a
#      restart. Delete that directory to start from nothing.
#   2. nats-server (plain core), *if* it is on your PATH.
#      Without them the app still runs — streaming and outbound
#      federation are simply off, and you are told so.
#   3. The combined release's projects (gateway + delivery + api in one
#      BEAM) on http://localhost:4000, with an IEx shell.
#
# The SPA dev server is a separate process on purpose — two programs
# writing to one terminal is worse than two terminals:
#
#   make dev-web        # http://localhost:5173, proxies API calls to :4000
#
# Ports are picked to not collide with a docker-compose stack or with
# `make test-pglite` (15433).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGLITE_PORT="${PGLITE_PORT:-15434}"
PGLITE_DATA="${PGLITE_DATA:-$ROOT/.pglite-dev}"
NATS_PORT="${NATS_PORT:-14223}"

# Shutting down is not instant: PGlite flushes its whole data directory
# (tens of MB) before it exits, so the ports stay held for a few seconds
# after you leave IEx. That is the flush, not a hang.
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}
# INT/TERM too: an untrapped signal would kill this shell without ever
# running the EXIT trap, orphaning PGlite and nats-server on the ports.
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

command -v bun >/dev/null 2>&1 || {
  echo "→ bun is needed for the embedded Postgres (https://bun.sh)" >&2
  exit 1
}

echo "→ PGlite on 127.0.0.1:$PGLITE_PORT  (data: ${PGLITE_DATA#"$ROOT"/})"
( cd "$ROOT/bun" && PGLITE_PORT="$PGLITE_PORT" PGLITE_DATA="$PGLITE_DATA" \
    exec bun run services/test_db.ts >/dev/null 2>&1 ) &
pids+=("$!")
wait_for_port "$PGLITE_PORT" "PGlite"

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

# The addon set stays the same either way, on purpose. Deriving it from
# which binaries happen to be installed would change which migration
# directories `sukhi.migrate` walks, and an addon switched on later
# brings migrations *below* the ones already applied — which
# `SukhiFedi.Release.check_migration_sanity/0` rightly refuses. Without
# NATS the streaming addon just logs that it can't connect.

# Read by config/dev.exs, which puts Oban in its inline posture: Oban
# opens a connection outside the pool that PGlite cannot serve.
export PGLITE=1
export DB_PORT="$PGLITE_PORT"
# One connection, deliberately. PGlite is a single Postgres that its
# socket server multiplexes several client connections onto, and that
# multiplexing breaks Postgrex's message ordering inside transactions:
# a write lands as `no function clause matching in
# Postgrex.Protocol.handle_msg/3` on `{:msg_command_complete, "BEGIN"}`.
# Reads survive it; posting a status does not. With a single connection
# there is nothing to interleave, and everything — Oban's queues
# included — behaves. Raise it only against a real Postgres.
export DB_POOL_SIZE="${DB_POOL_SIZE:-1}"
export NATS_PORT

cd "$ROOT/combined"
echo "→ migrating"
mix sukhi.migrate

echo "→ http://localhost:4000   (SPA dev server: \`make dev-web\` in another terminal)"

# Deliberately not `exec`: that would replace this shell, and the EXIT
# trap above would never run — leaving PGlite and nats-server holding
# their ports after every session.
iex -S mix
