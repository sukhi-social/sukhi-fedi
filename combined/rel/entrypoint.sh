#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Combined (gateway + delivery + api in one BEAM) container entrypoint,
# for the docker-compose stack and the x64 free-tier box.
#
# It is deliberately thin. The cookie, the fail-closed check and the
# "the api plugin node is this node" defaults all moved to rel/env.sh.eex,
# because the release's own boot script sources env.sh for every way of
# launching it (start, eval, rpc), and anything left here would silently
# not happen on the ones that skip this entrypoint.
set -eu

require_env() {
  name=$1
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "[entrypoint] refusing to boot: set $name" >&2
    exit 1
  fi
}

check_data_dir() {
  dir=${DATALEVIN_DIR:-/var/lib/sukhi/datalevin}
  if ! mkdir -p "$dir"; then
    echo "[entrypoint] refusing to boot: DATALEVIN_DIR is not creatable: $dir" >&2
    exit 1
  fi

  probe="$dir/.sukhi-write-test.$$"
  if ! (umask 077 && : >"$probe") 2>/dev/null; then
    echo "[entrypoint] refusing to boot: DATALEVIN_DIR is not writable: $dir" >&2
    exit 1
  fi
  rm -f "$probe"
  echo "[entrypoint] datalevin_dir=$dir writable=true"
}

check_instance_config() {
  path=${SUKHI_INSTANCE_CONFIG:-/etc/sukhi/instance.json}
  if [ ! -r "$path" ]; then
    echo "[entrypoint] refusing to boot: instance config is missing or unreadable: $path" >&2
    echo "[entrypoint] next: sukhi user must mount a readable JSON file at $path" >&2
    echo "[entrypoint] existing data was not opened or changed" >&2
    exit 1
  fi
  echo "[entrypoint] instance_config=$path readable=true"
}

# One BEAM, reachable only from inside this container. Long name, so the
# sname hostname guess never enters into it.
: "${RELEASE_DISTRIBUTION:=name}"
: "${RELEASE_NODE:=combined@127.0.0.1}"
export RELEASE_DISTRIBUTION RELEASE_NODE
echo "[entrypoint] node=$RELEASE_NODE"

# Secrets handed over as files (the host mounts /run/sukhi-secrets here,
# read-only): one file per variable, the file name is the variable name.
# A variable that is already set wins, so nothing changes where no files
# are mounted. Values are never echoed.
if [ -d /run/secrets ]; then
  for f in /run/secrets/*; do
    [ -f "$f" ] || continue
    n=$(basename "$f")
    eval "[ -n \"\${$n:-}\" ]" || export "$n=$(cat "$f")"
  done
fi

# Keep these checks here, before the one-shot eval, so a failed first boot
# explains the operator action in the journal instead of surfacing as a
# generic release/configuration error. Values are intentionally never logged.
require_env DOMAIN
require_env SECRET_KEY_BASE
if [ -z "${ERLANG_COOKIE:-}" ] && [ -z "${RELEASE_COOKIE:-}" ]; then
  echo "[entrypoint] refusing to boot: set ERLANG_COOKIE" >&2
  exit 1
fi
if [ "${ERLANG_COOKIE:-${RELEASE_COOKIE:-}}" = "sukhi_fedi_dev_cookie" ]; then
  echo "[entrypoint] refusing to boot: ERLANG_COOKIE must not use the published dev default" >&2
  exit 1
fi

if [ "${SUKHI_STORE:-postgres}" = "datalevin" ]; then
  check_data_dir
else
  echo "[entrypoint] store=${SUKHI_STORE:-postgres} (persistent directory check skipped)"
fi

check_instance_config

# Delivery never migrates — the schema stays gateway-owned even when the
# apps share a VM.
echo "[entrypoint] startup_preflight_start"
/app/bin/combined eval 'SukhiFedi.Release.check_runtime_connections!(); SukhiFedi.Release.migrate_all()'
echo "[entrypoint] startup_checks_complete"
exec /app/bin/combined start
