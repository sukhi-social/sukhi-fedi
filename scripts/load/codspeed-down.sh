#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Stop what codspeed-up.sh started.
OUT="${OUT:-$(cd "$(dirname "$0")/../.." && pwd)/scripts/load/out}"
[ -f "$OUT/pids" ] || exit 0
while read -r pid; do kill "$pid" 2>/dev/null || true; done <"$OUT/pids"
