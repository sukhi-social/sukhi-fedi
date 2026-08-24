#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Combined (gateway + delivery + api in one BEAM) container entrypoint,
# for the docker-compose stack and the x64 free-tier box.
#
# It is deliberately thin. The cookie, the fail-closed check and the
# "the api plugin node is this node" defaults all moved to rel/env.sh.eex,
# because DeployEx runs bin/combined without any entrypoint at all and
# anything left here would silently not happen there.
set -eu

# One BEAM, reachable only from inside this container. Long name, so the
# sname hostname guess never enters into it.
: "${RELEASE_DISTRIBUTION:=name}"
: "${RELEASE_NODE:=combined@127.0.0.1}"
export RELEASE_DISTRIBUTION RELEASE_NODE
echo "[entrypoint] node=$RELEASE_NODE"

# Delivery never migrates — the schema stays gateway-owned even when the
# apps share a VM. Under DeployEx this is a pre_command in current.json.
/app/bin/combined eval 'SukhiFedi.Release.migrate_all()'
exec /app/bin/combined start
