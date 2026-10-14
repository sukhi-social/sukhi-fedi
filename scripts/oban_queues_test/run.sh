#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Runs scripts/oban_queues_check.jl on each tree here and compares what it
# prints and its exit code with `<tree>.expected`.
#
#   TSUBAKIC="node .../tsubakic.bc.wasm.js"  TSBVM=.../tsbvm  scripts/oban_queues_test/run.sh
#
# UPDATE=1 rewrites the .expected files from the current output (read the
# diff before trusting it).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tsb="$(mktemp -d)/check.tsb"
: "${TSUBAKIC:?set TSUBAKIC to the command that folds a .jl, e.g. 'node _build/default/bin/tsubakic.bc.wasm.js'}"
: "${TSBVM:?set TSBVM to the tsbvm binary}"
$TSUBAKIC "$tsb" "$here/../oban_queues_check.jl" >/dev/null

fail=0
for tree in "$here"/*/; do
  name="$(basename "$tree")"
  actual="$(SUKHI_ROOT="$tree" $TSBVM "$tsb" 2>&1 | sed "s#$tree##g"; echo "exit=${PIPESTATUS[0]}")"
  if [[ "${UPDATE:-}" == 1 ]]; then printf '%s\n' "$actual" > "$here/$name.expected"; continue; fi
  if [[ "$actual" == "$(cat "$here/$name.expected")" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name"; diff <(printf '%s\n' "$actual") "$here/$name.expected" || true; fail=1
  fi
done
exit $fail
