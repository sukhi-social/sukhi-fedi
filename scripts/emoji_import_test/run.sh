#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Folds host_mock.jl + scenario_X.jl + ../emoji_import.jl, runs it on tsbvm, and
# compares everything it printed (the mock prints each request the script
# makes) plus the exit code with scenario_X.expected.
#
#   TSUBAKIC="node .../tsubakic.bc.wasm.js" TSBVM=.../tsbvm scripts/emoji_import_test/run.sh
#
# UPDATE=1 rewrites the .expected files from the current output -- read the
# diff before trusting it.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
: "${TSUBAKIC:?set TSUBAKIC to the command that folds a .jl}"
: "${TSBVM:?set TSBVM to the tsbvm binary}"
work="$(mktemp -d)"

fail=0
for scenario in "$here"/scenario_*.jl; do
  name="$(basename "$scenario" .jl)"
  $TSUBAKIC "$work/$name.tsb" "$here/host_mock.jl" "$scenario" "$here/../emoji_import.jl" >/dev/null
  actual="$($TSBVM "$work/$name.tsb" 2>&1; echo "exit=$?")"
  if [[ "${UPDATE:-}" == 1 ]]; then printf '%s\n' "$actual" > "$here/$name.expected"; continue; fi
  if [[ "$actual" == "$(cat "$here/$name.expected")" ]]; then
    echo "ok   ${name#scenario_}"
  else
    echo "FAIL ${name#scenario_}"; diff <(printf '%s\n' "$actual") "$here/$name.expected" || true; fail=1
  fi
done
exit $fail
