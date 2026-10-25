#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# How often each container hit its CPU ceiling during a load run. Run on the
# box that runs the containers (cgroup v2), around scripts/load/run.mjs:
#
#   scripts/load/cgroup_throttle.sh before   # writes a snapshot
#   node scripts/load/run.mjs ...
#   scripts/load/cgroup_throttle.sh after    # prints the difference
#
# `nr_throttled` is the number of 100 ms periods in which the container
# wanted more CPU than `--cpus` allowed; `throttled_usec` is the time it
# spent waiting. A container with a big number here, while the box as a whole
# is idle, is the case for moving from `cpus` to `cpu.weight`.
#
# Containers default to every running one; pass names to narrow it.
# Not run in CI (needs docker and cgroup v2).
set -euo pipefail

snap="${LOAD_CGROUP_SNAPSHOT:-/tmp/sukhi-cgroup-before.txt}"
mode="${1:?usage: $0 before|after [container...]}"
shift || true
names=("$@")
[ ${#names[@]} -eq 0 ] && mapfile -t names < <(docker ps --format '{{.Names}}')

read_stats() {
  for n in "${names[@]}"; do
    id=$(docker inspect --format '{{.Id}}' "$n")
    f=$(ls /sys/fs/cgroup/system.slice/docker-"$id".scope/cpu.stat 2>/dev/null || true)
    [ -z "$f" ] && { echo "$n - - -" ; continue; }
    awk -v n="$n" '/^usage_usec/{u=$2} /^nr_throttled/{t=$2} /^throttled_usec/{w=$2} END{print n, u, t, w}' "$f"
  done
}

case "$mode" in
  before) read_stats > "$snap"; echo "snapshot written to $snap" ;;
  after)
    printf '%-24s %12s %12s %14s\n' container cpu_sec throttled_periods throttled_sec
    join <(sort "$snap") <(read_stats | sort) | awk '{
      if ($2 == "-" || $5 == "-") { printf "%-24s %12s\n", $1, "(no cgroup)"; next }
      printf "%-24s %12.1f %12d %14.1f\n", $1, ($5-$2)/1e6, $6-$3, ($7-$4)/1e6 }'
    ;;
  *) echo "usage: $0 before|after [container...]" >&2; exit 2 ;;
esac
