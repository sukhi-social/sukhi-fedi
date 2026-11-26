#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Start what the CodSpeed load benchmark (scripts/load/codspeed.yml) runs against, and leave it
# running: a pgrust for the job queues, then the combined release seeded like ci.sh does it,
# pinned to core 0. The next step of the job runs the benchmarks; codspeed-down.sh stops it.
#
#   scripts/load/codspeed-up.sh        # writes $OUT/env (BASE, LOAD_TOKEN_FILE) and $OUT/pids
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-$ROOT/scripts/load/out}"
PORT="${PGRUST_PORT:-15434}"
mkdir -p "$OUT"

# shellcheck source=../lib/pgrust.sh
. "$ROOT/scripts/lib/pgrust.sh"
pgrust_install
DATA="$(mktemp -d "${TMPDIR:-/tmp}/sukhi-pgrust-XXXXXX")"
pgrust_initdb "$DATA"
pgrust_start "$DATA" "$PORT" "$OUT/pgrust.log"
pgrust_createdb "$PORT" sukhi_fedi_dev

export MIX_ENV=dev DOMAIN=localhost DB_PORT="$PORT" DB_POOL_SIZE="${DB_POOL_SIZE:-10}"
export SUKHI_INSTANCE_CONFIG="$HERE/instance.json" LEGAL_FLAVOR=sukhi METRICS_TOKEN=bench-metrics
export LOAD_TOKEN_FILE="$OUT/head.token"
export DATALEVIN_DIR="$OUT/head.datalevin"
rm -rf "$DATALEVIN_DIR"

cd "$ROOT/combined"
mix deps.get
mix compile
mix sukhi.migrate
mix run "$HERE/seed.exs"

setsid nohup taskset -c 0 mix run --no-halt >"$OUT/server.log" 2>&1 &
server=$!
printf '%s\n%s\n' "$PGRUST_PID" "$server" >"$OUT/pids"

for _ in $(seq 1 120); do
  curl -fs http://127.0.0.1:4000/api/v1/instance >/dev/null && break
  sleep 1
done
curl -fs http://127.0.0.1:4000/api/v1/instance >/dev/null || { tail -50 "$OUT/server.log"; exit 1; }
echo "BASE=http://127.0.0.1:4000" >"$OUT/env"
echo "LOAD_TOKEN_FILE=$LOAD_TOKEN_FILE" >>"$OUT/env"
