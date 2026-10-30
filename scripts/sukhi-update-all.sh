#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Swap every sukhi-run image to ONE commit, using sukhi-swap-image.sh for each.
# combined-sha.yml tags all four images with the same `sha-<commit>`, so
# "production is at sha-abc1234" can mean all of them.
#
#   sukhi-update-all.sh plan  --sha sha-abc1234   # resolve and check every unit; change nothing
#   sukhi-update-all.sh apply --sha sha-abc1234 [--yes]
#
# Order is back to front: combined (gateway), then web, then anubis (the door).
# Every target is planned first; if any plan fails (unit missing, tag missing),
# nothing is changed. If an apply fails, that unit rolls itself back and the
# run stops; targets already switched stay on the new sha (run `rollback`
# for them with sukhi-swap-image.sh).
#
# Targets are "unit|image|local-name", one per line, overridable with
# SUKHI_TARGETS. Defaults match the unit names seen on the box (Cockpit).
# nats and rustfs are third-party images and are not touched here.
# Other settings (SUKHI_SCOPE, SUKHI_LANG, SUKHI_VERIFY, ...) pass through.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNER="${SUKHI_REPO_OWNER:-sukhi-social}"
TARGETS="${SUKHI_TARGETS:-sukhi-social|ghcr.io/$OWNER/sukhi-fedi-combined|localhost/sukhi-combined
sukhi-social-web|ghcr.io/$OWNER/sukhi-fedi-web-next|localhost/sukhi-web
sukhi-social-anubis|ghcr.io/$OWNER/sukhi-fedi-anubis|localhost/sukhi-anubis}"

cmd="${1:-plan}"; shift || true
SHA=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) SHA="${2:?--sha needs a value}"; shift 2 ;;
    -y|--yes) YES=1; shift ;;
    *) echo "error: unknown option: $1" >&2; exit 1 ;;
  esac
done
case "$cmd" in plan|apply) ;; *) echo "usage: $0 plan|apply --sha sha-<commit> [--yes]" >&2; exit 1 ;; esac
case "$SHA" in sha-*) ;; *) echo "error: --sha sha-<commit> is required (the tag combined-sha.yml made)" >&2; exit 1 ;; esac

run_one() { # mode unit image local
  SUKHI_UNIT="$2" SUKHI_LOCAL_NAME="$4" SUKHI_IMAGE_REF="$3:$SHA" \
    "$HERE/sukhi-swap-image.sh" "$1" ${5:+"$5"}
}

echo "#### plan ($SHA)"
while IFS='|' read -r unit image local_name; do
  [ -n "$unit" ] || continue
  echo "---- $unit"
  run_one plan "$unit" "$image" "$local_name"
done <<< "$TARGETS"
[ "$cmd" = plan ] && exit 0

if [ "$YES" != 1 ] && [ -t 0 ]; then
  printf 'apply to all of the above (Y/N)? '; read -r a
  case "$a" in [Yy]|[Yy][Ee][Ss]) ;; *) echo "cancelled. nothing was changed."; exit 1 ;; esac
fi

echo "#### apply"
while IFS='|' read -r unit image local_name; do
  [ -n "$unit" ] || continue
  echo "---- $unit"
  run_one apply "$unit" "$image" "$local_name" --yes || { echo "stopped at $unit; earlier targets stay on $SHA" >&2; exit 1; }
done <<< "$TARGETS"
