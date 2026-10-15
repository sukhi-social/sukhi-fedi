#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Runs a Tsubaki script that reads a repository tree (SUKHI_ROOT) against small
# fixture trees, and compares what it prints plus its exit code with
# `<tree>.expected`. A tree may carry an `.env` file of KEY=VALUE lines that
# are set for its run.
#
#   scripts/run_tree_tests.sh scripts/oban_queues_check.jl scripts/oban_queues_test
#   scripts/run_tree_tests.sh scripts/env_audit.jl         scripts/env_audit_test
#
#   TSUBAKIC  the command that folds a .jl into a .tsb, e.g.
#             'node _build/default/bin/tsubakic.bc.wasm.js'
#   TSBVM     the tsbvm binary (built with the host; see nyanrus/tsubaki)
#   UPDATE=1  rewrite the .expected files from the current output -- read the
#             diff before trusting it
set -euo pipefail
script="${1:?usage: run_tree_tests.sh SCRIPT.jl TREES_DIR}"
dir="${2:?usage: run_tree_tests.sh SCRIPT.jl TREES_DIR}"
: "${TSUBAKIC:?set TSUBAKIC to the command that folds a .jl}"
: "${TSBVM:?set TSBVM to the tsbvm binary}"

tsb="$(mktemp -d)/check.tsb"
$TSUBAKIC "$tsb" "$script" >/dev/null

fail=0
for tree in "$dir"/*/; do
  name="$(basename "$tree")"
  extra=()
  if [[ -f "$tree/.env" ]]; then
    # not mapfile: macOS still ships bash 3.2
    while IFS= read -r line; do extra+=("$line"); done < "$tree/.env"
  fi
  actual="$(env SUKHI_ROOT="$tree" ${extra[@]+"${extra[@]}"} $TSBVM "$tsb" 2>&1 | sed "s#$tree##g"; echo "exit=${PIPESTATUS[0]}")"
  if [[ "${UPDATE:-}" == 1 ]]; then printf '%s\n' "$actual" > "$dir/$name.expected"; continue; fi
  if [[ "$actual" == "$(cat "$dir/$name.expected")" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name"; diff <(printf '%s\n' "$actual") "$dir/$name.expected" || true; fail=1
  fi
done
exit $fail
