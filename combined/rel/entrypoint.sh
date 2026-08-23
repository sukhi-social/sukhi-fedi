#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Combined (gateway + delivery + api in one BEAM) container entrypoint.
# Same contract as the gateway's: run all pending migrations, then
# hand off to the release boot script. Delivery never migrates —
# schema stays gateway-owned even when the apps share a VM.
set -eu

# ERLANG_COOKIE → RELEASE_COOKIE rename, same as the gateway entrypoint
# (Kamal env can't do variable indirection).
: "${ERLANG_COOKIE:=}"
if [ -n "$ERLANG_COOKIE" ] && [ -z "${RELEASE_COOKIE:-}" ]; then
  export RELEASE_COOKIE="$ERLANG_COOKIE"
fi

# Fail closed: the distribution cookie is the only auth for Erlang
# distribution. Refuse to boot with no cookie or the published dev
# default.
if [ -z "${RELEASE_COOKIE:-}" ] || [ "${RELEASE_COOKIE:-}" = "sukhi_fedi_dev_cookie" ]; then
  echo "[entrypoint] refusing to boot: set ERLANG_COOKIE to a random secret (openssl rand -hex 32)" >&2
  exit 1
fi

COOKIE_FP=$(printf '%s' "${RELEASE_COOKIE:-(unset)}" | sha256sum | head -c 16)
echo "[entrypoint] combined cookie_fp=$COOKIE_FP"

# gateway ↔ api は :rpc で話す(ARCHITECTURE §2 rule 6)。この release では
# 両方が同じ BEAM に居るので、互いの「相手のノード名」は自分自身になる。
# `:=` なので明示された env が必ず勝つ ─ 別 container の api を持つ既存の
# compose(PLUGIN_NODES=api@api)は、ここを一切通らない。
#
# 自前で決めるときは sname の hostname 推測を避けて長い名前で固定する。
# 外から届く必要はない一本なので loopback で足りる。
: "${RELEASE_DISTRIBUTION:=name}"
: "${RELEASE_NODE:=combined@127.0.0.1}"
export RELEASE_DISTRIBUTION RELEASE_NODE
: "${PLUGIN_NODES:=$RELEASE_NODE}"
: "${GATEWAY_NODE:=$RELEASE_NODE}"
export PLUGIN_NODES GATEWAY_NODE
echo "[entrypoint] node=$RELEASE_NODE plugin_nodes=$PLUGIN_NODES"

/app/bin/combined eval 'SukhiFedi.Release.migrate_all()'
exec /app/bin/combined start
