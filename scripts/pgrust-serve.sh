#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# A throwaway pgrust server, in the foreground, for a program that wants a
# PostgreSQL on a port (hosi_store's test_helper.exs starts this):
#
#   scripts/pgrust-serve.sh PORT
#
# It fetches pgrust the first time (scripts/lib/pgrust.sh), makes an empty
# cluster whose database is `postgres` (user postgres, trusted locally), and
# listens on 127.0.0.1:PORT until it is sent SIGTERM or SIGINT; then it stops
# the server and removes the cluster. Nothing is kept between runs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${1:?usage: pgrust-serve.sh PORT}"

# shellcheck source=lib/pgrust.sh
. "$ROOT/scripts/lib/pgrust.sh"
pgrust_install

DATA="$(mktemp -d "${TMPDIR:-/tmp}/sukhi-pgrust-XXXXXX")"
# A signal ends the script at once (even while pgrust is still starting up);
# the EXIT trap then stops the server and removes the cluster.
trap 'pgrust_stop; rm -rf "$DATA"' EXIT
trap 'exit 143' INT TERM

pgrust_initdb "$DATA"
# fsync off: the data is thrown away, and a test is not about durability.
pgrust_start "$DATA" "$PORT" "$DATA/server.log" -c fsync=off
wait "$PGRUST_PID"
