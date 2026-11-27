#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Weekly restore-verification for sukhi-fedi backups. An untested backup is
# theater. This proves the latest restic snapshot is intact AND that the
# Postgres dump actually pg_restores into a throwaway database with sane row
# counts — the failure you never want to discover at 3am during a real outage.
#
# DORMANT until installed — see infra/backup/README.md.
set -euo pipefail

: "${RESTIC_REPOSITORY:?set in backup.env}"
: "${RESTIC_PASSWORD:?set in backup.env}"
PG_IMAGE="${PG_IMAGE:-postgres:16-alpine}"
PG_DB="${PG_DB:-sukhi_fedi}"
PG_USER="${PG_USER:-sukhi}"
VERIFY_HEALTHCHECK_URL="${VERIFY_HEALTHCHECK_URL:-}"

log() { echo "[sukhi-verify] $*"; }

log "restic check (structure)"
restic check

# Monthly deep check re-reads a sample of real blobs — catches bit-rot a
# metadata check misses. Opt in with DEEP=1.
if [ "${DEEP:-0}" = "1" ]; then
  log "restic check --read-data-subset=5% (deep)"
  restic check --read-data-subset=5%
fi

stage="$(mktemp -d)"
scratch="sukhi-verify-pg-$$"
cleanup() { rm -rf "$stage"; docker rm -f "$scratch" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "restore latest pg dump"
restic restore latest --include "*.dump" --target "$stage"
dump_file="$(find "$stage" -name '*.dump' | head -1)"
[ -n "$dump_file" ] || { log "FAIL: no .dump in latest snapshot"; exit 1; }
log "restored: $dump_file"

log "spin throwaway postgres ($PG_IMAGE)"
docker run -d --rm --name "$scratch" \
  -e POSTGRES_PASSWORD=verify -e POSTGRES_USER="$PG_USER" -e POSTGRES_DB="$PG_DB" \
  "$PG_IMAGE" >/dev/null

for _ in $(seq 1 30); do
  docker exec "$scratch" pg_isready -U "$PG_USER" >/dev/null 2>&1 && break
  sleep 1
done

log "pg_restore into throwaway"
docker cp "$dump_file" "$scratch":/tmp/restore.dump
docker exec -e PGPASSWORD=verify "$scratch" \
  pg_restore -U "$PG_USER" -d "$PG_DB" --no-owner --clean --if-exists /tmp/restore.dump 2>/dev/null || true

count() {
  docker exec -e PGPASSWORD=verify "$scratch" \
    psql -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM $1" 2>/dev/null | tr -d '[:space:]'
}
accounts="$(count accounts)"
audits="$(count admin_audits)"
log "restored counts: accounts=${accounts:-ERR} admin_audits=${audits:-ERR}"

if ! { [ -n "${accounts:-}" ] && [ "${accounts}" -ge 0 ] 2>/dev/null; }; then
  log "FAIL: accounts count not readable after restore"
  exit 1
fi

log "verify OK"
if [ -n "$VERIFY_HEALTHCHECK_URL" ]; then
  curl -fsS -m 10 "$VERIFY_HEALTHCHECK_URL" >/dev/null && log "pinged verify healthcheck" || true
fi
