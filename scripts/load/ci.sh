#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# One benchmark pass for CI: boot a checkout against the Postgres on :5432,
# seed it, load it with run.mjs, write the result to $OUT/<label>.json.
#
#   scripts/load/ci.sh <checkout-dir> <label>
#
# The server is pinned to one core (taskset), so the stages are crowded on
# purpose; Postgres runs beside it, unpinned. A runner is not the 0.5 OCPU
# box — the comparison between two labels on the same runner is the
# measurement, not the absolute numbers.
set -euo pipefail

SRC="$(cd "${1:?checkout dir}" && pwd)"
LABEL="${2:?label}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/out}"
mkdir -p "$OUT"

export PGPASSWORD=postgres
export MIX_ENV=dev
export DOMAIN=localhost
export METRICS_TOKEN=bench-metrics
export DB_POOL_SIZE="${DB_POOL_SIZE:-10}"
export LOAD_TOKEN_FILE="$OUT/$LABEL.token"

psql -h localhost -U postgres -c 'DROP DATABASE IF EXISTS sukhi_fedi_dev' -c 'CREATE DATABASE sukhi_fedi_dev'

cd "$SRC/combined"
mix deps.get
mix compile
mix sukhi.migrate
mix run "$HERE/seed.exs"

taskset -c 0 mix run --no-halt >"$OUT/$LABEL.server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  curl -fs http://127.0.0.1:4000/api/v1/instance >/dev/null && break
  sleep 1
done
curl -fs http://127.0.0.1:4000/api/v1/instance >/dev/null || { tail -50 "$OUT/$LABEL.server.log"; exit 1; }

node "$HERE/run.mjs" --base http://127.0.0.1:4000 --stages "${STAGES:-50,200,400,800}" --seconds "${SECONDS_PER_STAGE:-30}" \
  --token "$(paste -sd, "$LOAD_TOKEN_FILE")" --metrics-token "$METRICS_TOKEN" --out "$OUT/$LABEL.json"
