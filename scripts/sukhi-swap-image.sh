#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Swap one Quadlet-run image for a new one, by digest, and go back if the unit
# does not come up. A seed for `sukhi release` (SERVER_SHELL.md §5.1); the
# human-readable steps live in docs/OPS_UPDATE_QUADLET.md.
#
#   sukhi-swap-image.sh plan     [--tag REF]   # resolve and show; change nothing
#   sukhi-swap-image.sh apply    [--tag REF]   # copy, switch, check, roll back on failure
#   sukhi-swap-image.sh rollback               # go back to the previous image
#
# Settings (environment, all optional):
#   SUKHI_IMAGE_REF   default tag to follow   (ghcr.io/sukhi-social/sukhi-fedi-combined:v1)
#   SUKHI_UNIT        user unit to restart    (sukhi-gateway)
#   SUKHI_LOCAL_NAME  name in local storage   (localhost/sukhi-combined)
#   SUKHI_HEALTH_URL  checked after restart   (unset: only `is-active` is checked)
#   SUKHI_WAIT_SECS   how long to wait        (60)
#   SUKHI_STATE_DIR   current/previous record (${XDG_STATE_HOME:-~/.local/state}/sukhi-release)
#   SUKHI_QUADLET_DIR drop-in lives under it  (${XDG_CONFIG_HOME:-~/.config}/containers/systemd)
#
#   SUKHI_VERIFY      1 = cosign verify before copy (default), 0 = skip
#   SUKHI_SIGNER_RE   accepted signer identity (this repo's release.yml at a v* tag,
#                     or combined-sha.yml on main)
#
# Images are signed keyless by release.yml / combined-sha.yml (Sigstore); an image
# without a matching signature is refused. Images built before signing existed
# need SUKHI_VERIFY=0.
# Not yet run on a real box; see the "未確認" list in the doc.

set -euo pipefail

REF="${SUKHI_IMAGE_REF:-ghcr.io/sukhi-social/sukhi-fedi-combined:v1}"
UNIT="${SUKHI_UNIT:-sukhi-gateway}"
LOCAL="${SUKHI_LOCAL_NAME:-localhost/sukhi-combined}"
HEALTH="${SUKHI_HEALTH_URL:-}"
WAIT="${SUKHI_WAIT_SECS:-60}"
VERIFY="${SUKHI_VERIFY:-1}"
SIGNER_RE="${SUKHI_SIGNER_RE:-^https://github\\.com/sukhi-social/sukhi-fedi/\\.github/workflows/(release\\.yml@refs/tags/v.+|combined-sha\\.yml@refs/heads/main)$}"
STATE="${SUKHI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/sukhi-release}/$UNIT"
DROPIN_DIR="${SUKHI_QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}/$UNIT.container.d"
DROPIN="$DROPIN_DIR/10-image.conf"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "== $*"; }

cmd="${1:-plan}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) REF="${2:?--tag needs a value}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

for bin in skopeo systemctl $([ "$VERIFY" = 1 ] && echo cosign); do
  command -v "$bin" >/dev/null || die "$bin not found"
done

read_state() { [ -f "$STATE/$1" ] && cat "$STATE/$1" || true; }

# Point the drop-in at an image and restart. Prints nothing; returns the
# unit's health as the exit code.
switch_to() {
  local image="$1" i
  mkdir -p "$DROPIN_DIR"
  printf '[Container]\nImage=%s\n' "$image" > "$DROPIN.tmp"
  mv "$DROPIN.tmp" "$DROPIN"
  systemctl --user daemon-reload
  systemctl --user restart "$UNIT.service" || return 1
  for ((i = 0; i < WAIT; i++)); do
    if systemctl --user is-active --quiet "$UNIT.service" \
       && { [ -z "$HEALTH" ] || curl -fsS --max-time 3 "$HEALTH" >/dev/null 2>&1; }; then
      # A crash-looping unit can be "active" for a moment; require it to hold.
      sleep 3
      systemctl --user is-active --quiet "$UNIT.service" && return 0
    fi
    sleep 1
  done
  return 1
}

record() {
  mkdir -p "$STATE"
  local cur; cur="$(read_state current)"
  [ -n "$cur" ] && printf '%s\n' "$cur" > "$STATE/previous"
  printf '%s\n' "$1" > "$STATE/current"
  printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$1" "$2" >> "$STATE/history"
}

resolve() {
  local d
  d="$(skopeo inspect --no-tags --format '{{.Digest}}' "docker://$REF")" || die "cannot resolve $REF"
  case "$d" in sha256:*) printf '%s\n' "$d" ;; *) die "unexpected digest: $d" ;; esac
}

case "$cmd" in
  plan|apply)
    digest="$(resolve)"
    src="${REF%:*}@$digest"
    short="${digest#sha256:}"; short="${short:0:12}"
    target="$LOCAL:d-$short"
    current="$(read_state current)"
    say "tag        $REF"
    say "digest     $digest"
    say "will run   $target   (copied from $src)"
    say "now        ${current:-"(not recorded)"}"
    if [ "$current" = "$target" ]; then say "already running this image"; exit 0; fi
    [ "$cmd" = plan ] && { say "plan only. run with: apply"; exit 0; }

    if [ "$VERIFY" = 1 ]; then
      say "verify signature"
      cosign verify \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com \
        --certificate-identity-regexp "$SIGNER_RE" \
        "$src" >/dev/null || die "signature check failed for $src; nothing was changed"
    else
      say "verify skipped (SUKHI_VERIFY=0)"
    fi

    say "copy"
    skopeo copy "docker://$src" "containers-storage:$target"

    say "switch"
    if switch_to "$target"; then
      record "$target" "$REF"
      say "ok"
    else
      echo "unit did not become healthy" >&2
      prev="$(read_state current)"
      if [ -n "$prev" ]; then
        say "rolling back to $prev"
        switch_to "$prev" || die "rollback failed too; check: journalctl --user -u $UNIT"
      else
        rm -f "$DROPIN"; systemctl --user daemon-reload
        say "no previous image recorded; drop-in removed (unit uses its .container file)"
      fi
      exit 1
    fi
    ;;
  rollback)
    prev="$(read_state previous)"
    [ -n "$prev" ] || die "no previous image recorded"
    say "back to $prev"
    switch_to "$prev" || die "unit did not become healthy"
    # record() moves current -> previous, so a second rollback undoes this one.
    record "$prev" rollback
    ;;
  *) die "usage: $0 plan|apply|rollback [--tag REF]" ;;
esac
