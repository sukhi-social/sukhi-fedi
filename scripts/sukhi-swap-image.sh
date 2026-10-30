#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Swap one Quadlet-run image for a new one, by digest, and go back if the unit
# does not come up. A seed for `sukhi release` (SERVER_SHELL.md §5.1); the
# human-readable steps live in docs/OPS_UPDATE_QUADLET.md.
#
#   sukhi-swap-image.sh plan     [--tag REF]   # resolve and show; change nothing
#   sukhi-swap-image.sh apply    [--tag REF] [--yes]   # copy, switch, check, roll back on failure
#   sukhi-swap-image.sh rollback [--yes]               # go back to the previous image
#
# On a terminal, apply and rollback ask (Y/N)? first; --yes skips the question.
# Output is Japanese when SUKHI_LANG (or LANG) starts with ja.
#
# Settings (environment, all optional):
#   SUKHI_IMAGE_REF   default tag to follow   (ghcr.io/sukhi-social/sukhi-fedi-combined:v1)
#   SUKHI_UNIT        unit to restart         (sukhi-gateway; the .container file's name)
#   SUKHI_SCOPE       user | system           (user; system = rootful Quadlet under /etc)
#   SUKHI_LOCAL_NAME  name in local storage   (localhost/sukhi-combined)
#   SUKHI_HEALTH_URL  checked after restart   (unset: only `is-active` is checked)
#   SUKHI_WAIT_SECS   how long to wait        (60)
#   SUKHI_STATE_DIR   current/previous record (${XDG_STATE_HOME:-~/.local/state}/sukhi-release)
#   SUKHI_QUADLET_DIR drop-in lives under it  (${XDG_CONFIG_HOME:-~/.config}/containers/systemd)
#
#   SUKHI_LANG        ja | en                 (ja when $LANG starts with ja, else en)
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
SCOPE="${SUKHI_SCOPE:-user}"
case "$SCOPE" in
  user)   SCTL=(systemctl --user); QDIR_DEFAULT="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd" ;;
  system) SCTL=(systemctl);        QDIR_DEFAULT=/etc/containers/systemd ;;
  *) echo "error: SUKHI_SCOPE must be user or system (user か system)" >&2; exit 1 ;;
esac
LOCAL="${SUKHI_LOCAL_NAME:-localhost/sukhi-combined}"
HEALTH="${SUKHI_HEALTH_URL:-}"
WAIT="${SUKHI_WAIT_SECS:-60}"
VERIFY="${SUKHI_VERIFY:-1}"
SIGNER_RE="${SUKHI_SIGNER_RE:-^https://github\\.com/sukhi-social/sukhi-fedi/\\.github/workflows/(release\\.yml@refs/tags/v.+|combined-sha\\.yml@refs/heads/main)$}"
STATE="${SUKHI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/sukhi-release}/$UNIT"
DROPIN_DIR="${SUKHI_QUADLET_DIR:-$QDIR_DEFAULT}/$UNIT.container.d"
DROPIN="$DROPIN_DIR/10-image.conf"

# Messages. Japanese follows the MS-DOS (J) manner: one short line saying what
# happened, then what to do next; questions end in (Y/N)?; no decoration.
case "${SUKHI_LANG:-${LANG:-}}" in ja*) LANGX=ja ;; *) LANGX=en ;; esac

t() {
  local k="$1"; shift
  if [ "$LANGX" = ja ]; then
    case "$k" in
      tag)        printf 'タグ          %s' "$1" ;;
      digest)     printf 'ダイジェスト  %s' "$1" ;;
      willrun)    printf '入れる image   %s (取得元 %s)' "$1" "$2" ;;
      now)        printf '今の image     %s' "${1:-(記録なし)}" ;;
      same)       printf '同じ image が動いています。何もしません。' ;;
      planonly)   printf '確認だけです。入れ替えるには apply を指定してください。' ;;
      confirm)    printf '入れ替えを続行しますか (Y/N)? ' ;;
      cancelled)  printf '中止しました。何も変更していません。' ;;
      verify)     printf '署名を確認しています' ;;
      noverify)   printf '署名の確認を省きました (SUKHI_VERIFY=0)' ;;
      badsig)     printf '署名を確認できません: %s\n何も変更していません。' "$1" ;;
      copy)       printf 'image を取得しています' ;;
      switch)     printf '切り替えて再起動しています' ;;
      ok)         printf '完了しました' ;;
      unhealthy)  printf 'ユニットが正常になりません' ;;
      rollingback) printf '前の image に戻しています: %s' "$1" ;;
      rbfailed)   printf '戻すのにも失敗しました。確認: journalctl %s-u %s' "$1" "$2" ;;
      noprev_drop) printf '前の image の記録がありません。drop-in を消しました (.container の image に戻ります)' ;;
      noprev)     printf '前の image の記録がありません' ;;
      back)       printf '前の image に戻します: %s' "$1" ;;
      nobin)      printf '%s が見つかりません' "$1" ;;
      noresolve)  printf '%s を解決できません' "$1" ;;
      baddigest)  printf '想定外のダイジェストです: %s' "$1" ;;
      badopt)     printf 'オプションが違います: %s' "$1" ;;
      usage)      printf '使い方: %s plan|apply|rollback [--tag REF] [--yes]' "$1" ;;
      nounit)     printf '%s のユニット %s.service が見つかりません。何も変更していません。\n  - ユニット名は .container ファイルの名前です (sukhi-gateway.container → sukhi-gateway.service)\n  - 探す:  %s list-units --all '"'sukhi*'"'  (SUKHI_SCOPE=system や SUKHI_UNIT=... を試す)\n  - Quadlet は daemon-reload でユニットを作ります。作られるもの:\n      /usr/lib/systemd/system-generators/podman-system-generator [--user] --dryrun\n  - rootless で ssh 越しなら XDG_RUNTIME_DIR が必要です (su でなく、直接 ssh で入る)' "$1" "$2" "$3" ;;
    esac
  else
    case "$k" in
      tag)        printf 'tag        %s' "$1" ;;
      digest)     printf 'digest     %s' "$1" ;;
      willrun)    printf 'will run   %s   (copied from %s)' "$1" "$2" ;;
      now)        printf 'now        %s' "${1:-(not recorded)}" ;;
      same)       printf 'already running this image' ;;
      planonly)   printf 'plan only. run with: apply' ;;
      confirm)    printf 'Continue (Y/N)? ' ;;
      cancelled)  printf 'cancelled. nothing was changed.' ;;
      verify)     printf 'verify signature' ;;
      noverify)   printf 'verify skipped (SUKHI_VERIFY=0)' ;;
      badsig)     printf 'signature check failed for %s; nothing was changed' "$1" ;;
      copy)       printf 'copy' ;;
      switch)     printf 'switch' ;;
      ok)         printf 'ok' ;;
      unhealthy)  printf 'unit did not become healthy' ;;
      rollingback) printf 'rolling back to %s' "$1" ;;
      rbfailed)   printf 'rollback failed too; check: journalctl %s-u %s' "$1" "$2" ;;
      noprev_drop) printf 'no previous image recorded; drop-in removed (unit uses its .container file)' ;;
      noprev)     printf 'no previous image recorded' ;;
      back)       printf 'back to %s' "$1" ;;
      nobin)      printf '%s not found' "$1" ;;
      noresolve)  printf 'cannot resolve %s' "$1" ;;
      baddigest)  printf 'unexpected digest: %s' "$1" ;;
      badopt)     printf 'unknown option: %s' "$1" ;;
      usage)      printf 'usage: %s plan|apply|rollback [--tag REF] [--yes]' "$1" ;;
      nounit)     printf '%s unit %s.service not found; nothing was changed.\n  - the unit is named after the .container file (sukhi-gateway.container -> sukhi-gateway.service)\n  - find it:  %s list-units --all '"'sukhi*'"'   (try SUKHI_SCOPE=system, or SUKHI_UNIT=...)\n  - Quadlet generates units on daemon-reload; to see what it makes:\n      /usr/lib/systemd/system-generators/podman-system-generator [--user] --dryrun\n  - over ssh as a rootless user, XDG_RUNTIME_DIR must be set (log in directly with ssh, not su)' "$1" "$2" "$3" ;;
    esac
  fi
}

die() { echo "error: $(t "$@")" >&2; exit 1; }
say() { echo "== $(t "$@")"; }

YES=0
cmd="${1:-plan}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) REF="${2:?--tag needs a value}"; shift 2 ;;
    -y|--yes) YES=1; shift ;;
    *) die badopt "$1" ;;
  esac
done

for bin in skopeo systemctl $([ "$VERIFY" = 1 ] && echo cosign); do
  command -v "$bin" >/dev/null || die nobin "$bin"
done

# Fail before changing anything if the unit is not there: a wrong name, the
# wrong scope, or no Quadlet-generated unit yet.
check_unit() {
  "${SCTL[@]}" cat "$UNIT.service" >/dev/null 2>&1 && return 0
  echo "error: $(t nounit "$SCOPE" "$UNIT" "${SCTL[*]}")" >&2
  exit 1
}

# DOS-style confirmation. Only asks on a terminal; scripts pass --yes.
confirm() {
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || return 0
  local a
  while :; do
    printf '%s' "$(t confirm)"; read -r a || return 1
    case "$a" in [Yy]|[Yy][Ee][Ss]) return 0 ;; [Nn]|[Nn][Oo]|"") return 1 ;; esac
  done
}

read_state() { [ -f "$STATE/$1" ] && cat "$STATE/$1" || true; }

# Point the drop-in at an image and restart. Prints nothing; returns the
# unit's health as the exit code.
switch_to() {
  local image="$1" i
  mkdir -p "$DROPIN_DIR"
  printf '[Container]\nImage=%s\n' "$image" > "$DROPIN.tmp"
  mv "$DROPIN.tmp" "$DROPIN"
  "${SCTL[@]}" daemon-reload
  "${SCTL[@]}" restart "$UNIT.service" || return 1
  for ((i = 0; i < WAIT; i++)); do
    if "${SCTL[@]}" is-active --quiet "$UNIT.service" \
       && { [ -z "$HEALTH" ] || curl -fsS --max-time 3 "$HEALTH" >/dev/null 2>&1; }; then
      # A crash-looping unit can be "active" for a moment; require it to hold.
      sleep 3
      "${SCTL[@]}" is-active --quiet "$UNIT.service" && return 0
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
  d="$(skopeo inspect --no-tags --format '{{.Digest}}' "docker://$REF")" || die noresolve "$REF"
  case "$d" in sha256:*) printf '%s\n' "$d" ;; *) die baddigest "$d" ;; esac
}

JCTL_USER=""; [ "$SCOPE" = user ] && JCTL_USER="--user "

case "$cmd" in
  plan|apply)
    digest="$(resolve)"
    src="${REF%:*}@$digest"
    short="${digest#sha256:}"; short="${short:0:12}"
    target="$LOCAL:d-$short"
    current="$(read_state current)"
    say tag "$REF"
    say digest "$digest"
    say willrun "$target" "$src"
    say now "$current"
    check_unit
    if [ "$current" = "$target" ]; then say same; exit 0; fi
    [ "$cmd" = plan ] && { say planonly; exit 0; }
    confirm || { say cancelled; exit 1; }

    if [ "$VERIFY" = 1 ]; then
      say verify
      cosign verify \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com \
        --certificate-identity-regexp "$SIGNER_RE" \
        "$src" >/dev/null || die badsig "$src"
    else
      say noverify
    fi

    say copy
    skopeo copy "docker://$src" "containers-storage:$target"

    say switch
    if switch_to "$target"; then
      record "$target" "$REF"
      say ok
    else
      echo "error: $(t unhealthy)" >&2
      prev="$(read_state current)"
      if [ -n "$prev" ]; then
        say rollingback "$prev"
        switch_to "$prev" || die rbfailed "$JCTL_USER" "$UNIT"
      else
        rm -f "$DROPIN"; "${SCTL[@]}" daemon-reload
        say noprev_drop
      fi
      exit 1
    fi
    ;;
  rollback)
    prev="$(read_state previous)"
    [ -n "$prev" ] || die noprev
    say back "$prev"
    confirm || { say cancelled; exit 1; }
    switch_to "$prev" || die unhealthy
    # record() moves current -> previous, so a second rollback undoes this one.
    record "$prev" rollback
    say ok
    ;;
  *) die usage "$0" ;;
esac
