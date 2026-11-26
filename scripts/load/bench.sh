#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# bench.mjs on the core codspeed-up.sh chose for the client (CLIENT_CPU), if it chose one.
exec ${CLIENT_CPU:+taskset -c "$CLIENT_CPU"} node "$(dirname "$0")/bench.mjs" "$@"
