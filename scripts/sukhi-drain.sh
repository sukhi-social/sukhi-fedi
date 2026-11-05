#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Quiet the server, then copy its data, before switching it off. The host-side
# door to SukhiFedi.Maintenance.Drain (docs/OPS_DRAIN_BACKUP.ja.md): it calls
# the running node through `podman exec … bin/combined rpc` and shows what the
# node says. Nothing here decides anything; the order and the checks live in
# the app.
#
#   sukhi-drain.sh status                         # where things stand; changes nothing
#   sukhi-drain.sh close  [options]               # shut the door, wait until nothing writes
#   sukhi-drain.sh backup                         # copy (only on a closed, settled server)
#   sukhi-drain.sh run    [--stop] [options]      # close + backup [+ stop the unit]
#   sukhi-drain.sh open                           # resume the queues, open the door
#
# options (close / run):
#   --reason WORD    shown to visitors            (maintenance)
#   --retry SECS     Retry-After for refused calls (300)
#   --until ISO8601  when you expect to be back   (not shown if omitted)
#   --timeout SECS   how long to wait for the outbox to flush and the queues to
#                    stand still, each            (60)
#
# `run` leaves the door closed on purpose: the next step is the shutdown, and a
# fresh process is always open. On any failure the door STAYS closed and the
# unit is NOT stopped; read the last line, then run it again or `open`.
#
# Settings (environment, all optional):
#   SUKHI_CONTAINER   the gateway container  (sukhi-gateway)
#   SUKHI_UNIT        the unit `--stop` stops (sukhi-gateway)
#   SUKHI_SCOPE       user | system          (user)
#   SUKHI_RELEASE_BIN the release script, inside the container (/app/bin/combined)
#   SUKHI_VOLUME      the data volume        (sukhi-data; mounted at /var/lib/sukhi)
#   SUKHI_BACKUP_HOOK a command run after a good backup, e.g. an off-host copy:
#                       SUKHI_BACKUP_HOOK='restic backup "$SUKHI_BACKUP_HOST_DIR"'
#                     it sees SUKHI_BACKUP_DIR (inside the container) and
#                     SUKHI_BACKUP_HOST_DIR (on this host). If it fails, the
#                     unit is not stopped.
#   SUKHI_LANG        ja | en                (ja when $LANG starts with ja, else en)
#
# Exit status: 0 ok · 1 usage · 2 the server said no · 3 the hook failed ·
#              4 could not reach the server.
# Not yet run on a real box; see the "未確認" list in the doc.

set -euo pipefail

CONTAINER="${SUKHI_CONTAINER:-sukhi-gateway}"
UNIT="${SUKHI_UNIT:-sukhi-gateway}"
SCOPE="${SUKHI_SCOPE:-user}"
BIN="${SUKHI_RELEASE_BIN:-/app/bin/combined}"
VOLUME="${SUKHI_VOLUME:-sukhi-data}"
HOOK="${SUKHI_BACKUP_HOOK:-}"
case "$SCOPE" in
  user)   SCTL=(systemctl --user) ;;
  system) SCTL=(systemctl) ;;
  *) echo "error: SUKHI_SCOPE must be user or system (user か system)" >&2; exit 1 ;;
esac
case "${SUKHI_LANG:-${LANG:-}}" in ja*) LANGX=ja ;; *) LANGX=en ;; esac

# Messages: one short line saying what happened, then what to do next.
t() {
  local k="$1"; shift
  if [ "$LANGX" = ja ]; then
    case "$k" in
      usage)        echo "使い方: sukhi-drain.sh status | close | backup | run [--stop] | open  (--reason WORD --retry SECS --until ISO8601 --timeout SECS)" ;;
      bad_opt)      echo "オプションが読めません: $1" ;;
      no_server)    echo "サーバーに届きません($CONTAINER)。動いていますか: podman ps" ;;
      no_answer)    echo "サーバーから結果の行が返りませんでした。上の出力を見てください。" ;;
      failed)       echo "止められませんでした: $1" ;;
      stays_closed) echo "受付は止めたままです。もう一度 run するか、open で戻せます。ユニットは止めていません。" ;;
      s_closed)     echo "受付を止めました" ;;
      s_http)       echo "いまの通信が終わるのを待ちました(余裕 ${1} ミリ秒)" ;;
      s_flush)      echo "投稿の送り出しの仕分けが空になりました" ;;
      s_paused)     echo "キューを止めて、動いている仕事がないことを確かめました" ;;
      s_settled)    echo "静かになりました($1)" ;;
      s_bstart)     echo "控えを取ります" ;;
      s_bdone)      echo "控えが取れて、開けることも確かめました" ;;
      s_resumed)    echo "キューを再開しました" ;;
      s_open)       echo "受付を再開しました" ;;
      backup_at)    echo "控え: $1" ;;
      hook_run)     echo "SUKHI_BACKUP_HOOK を実行します" ;;
      hook_failed)  echo "SUKHI_BACKUP_HOOK が失敗しました。ユニットは止めていません。控えはサーバーに残っています。" ;;
      no_host_dir)  echo "控えの場所がボリューム($VOLUME)の外です。SUKHI_BACKUP_HOST_DIR は空で hook を呼びます。" ;;
      stopping)     echo "ユニット $UNIT を止めます。受付は止めたまま、次の起動で開きます。" ;;
      stopped)      echo "ユニットを止めました" ;;
      ready)        echo "控えまで済みました。ユニットはまだ動いています(--stop を付けると止めます)。" ;;
      *) echo "$k" ;;
    esac
  else
    case "$k" in
      usage)        echo "usage: sukhi-drain.sh status | close | backup | run [--stop] | open  (--reason WORD --retry SECS --until ISO8601 --timeout SECS)" ;;
      bad_opt)      echo "cannot read option: $1" ;;
      no_server)    echo "cannot reach the server ($CONTAINER). Is it running? podman ps" ;;
      no_answer)    echo "the server printed no result line; read the output above." ;;
      failed)       echo "could not drain: $1" ;;
      stays_closed) echo "the door stays closed. Run it again, or open. The unit was not stopped." ;;
      s_closed)     echo "door closed" ;;
      s_http)       echo "requests in flight have left (grace ${1} ms)" ;;
      s_flush)      echo "the outbox is flushed" ;;
      s_paused)     echo "queues paused; no job is running" ;;
      s_settled)    echo "settled ($1)" ;;
      s_bstart)     echo "taking the backup" ;;
      s_bdone)      echo "backup taken, and read back" ;;
      s_resumed)    echo "queues resumed" ;;
      s_open)       echo "door open" ;;
      backup_at)    echo "backup: $1" ;;
      hook_run)     echo "running SUKHI_BACKUP_HOOK" ;;
      hook_failed)  echo "SUKHI_BACKUP_HOOK failed. The unit was not stopped; the backup is still on the server." ;;
      no_host_dir)  echo "the backup is outside the volume ($VOLUME); calling the hook with an empty SUKHI_BACKUP_HOST_DIR." ;;
      stopping)     echo "stopping unit $UNIT. The door stays closed; the next start opens it." ;;
      stopped)      echo "unit stopped" ;;
      ready)        echo "backup done. The unit is still running (add --stop to stop it)." ;;
      *) echo "$k" ;;
    esac
  fi
}

die() { echo "$(t "$@")" >&2; exit "${DIE_CODE:-1}"; }

# ── Reading the options ────────────────────────────────────────────────────
ACTION="${1:-}"; [ $# -gt 0 ] && shift
STOP=0; REASON=""; RETRY=""; UNTIL=""; TIMEOUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stop)    STOP=1; shift ;;
    --reason)  REASON="${2:-}"; shift 2 || die bad_opt "$1" ;;
    --retry)   RETRY="${2:-}"; shift 2 || die bad_opt "$1" ;;
    --until)   UNTIL="${2:-}"; shift 2 || die bad_opt "$1" ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 || die bad_opt "$1" ;;
    *) die bad_opt "$1" ;;
  esac
done
case "$ACTION" in status|close|backup|run|open) ;; *) t usage >&2; exit 1 ;; esac
[ "$STOP" = 0 ] || [ "$ACTION" = run ] || die bad_opt "--stop (run only)"

# Everything that reaches the Elixir expression is checked here first: the
# expression is built from these strings.
[ -z "$REASON" ]  || [[ "$REASON" =~ ^[A-Za-z0-9_-]{1,40}$ ]]                  || die bad_opt "--reason $REASON"
[ -z "$RETRY" ]   || [[ "$RETRY" =~ ^[0-9]{1,6}$ && "$RETRY" -gt 0 ]]          || die bad_opt "--retry $RETRY"
[ -z "$UNTIL" ]   || [[ "$UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9:]+)$ ]] || die bad_opt "--until $UNTIL"
[ -z "$TIMEOUT" ] || [[ "$TIMEOUT" =~ ^[0-9]{1,5}$ && "$TIMEOUT" -gt 0 ]]      || die bad_opt "--timeout $TIMEOUT"

opts=""
[ -z "$REASON" ]  || opts="$opts, reason: \"$REASON\""
[ -z "$RETRY" ]   || opts="$opts, retry_after_s: $RETRY"
[ -z "$UNTIL" ]   || opts="$opts, until: \"$UNTIL\""
[ -z "$TIMEOUT" ] || opts="$opts, flush_timeout_ms: $((TIMEOUT * 1000)), idle_timeout_ms: $((TIMEOUT * 1000))"

# ── Calling the node ───────────────────────────────────────────────────────
# Inside the container the cookie is a mounted secret file, not an env var (the
# entrypoint reads it into its own environment only), so read it here, for this
# one process. The secret never leaves the container.
rpc_expr() {
  podman exec "$CONTAINER" sh -c '
    if [ -z "${ERLANG_COOKIE:-}" ] && [ -r /run/secrets/ERLANG_COOKIE ]; then
      ERLANG_COOKIE=$(cat /run/secrets/ERLANG_COOKIE); export ERLANG_COOKIE
    fi
    export RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-name}" RELEASE_NODE="${RELEASE_NODE:-combined@127.0.0.1}"
    exec "$0" rpc "$1"
  ' "$BIN" "$1"
}

OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
RESULT=""

# Run one Drain action; print its steps in words; leave the RESULT line in $RESULT.
drain() {
  local action="$1"
  local expr="SukhiFedi.Maintenance.Drain.cli(:$action${opts})"
  : >"$OUT"
  if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    DIE_CODE=4 die no_server
  fi
  rpc_expr "$expr" 2>&1 | tee "$OUT" | render || true
  RESULT="$(grep '^RESULT ' "$OUT" | tail -n 1 || true)"
  [ -n "$RESULT" ] || { echo "$(t no_answer)" >&2; return 4; }
  case "$RESULT" in "RESULT ok"*) return 0 ;; *) return 2 ;; esac
}

# STEP lines → words. Anything else (a stack trace, a warning) is shown as is.
render() {
  local line detail
  while IFS= read -r line; do
    case "$line" in
      "STEP intake_closed"*)   echo "  ✓ $(t s_closed)" ;;
      "STEP http_settled"*)    detail="${line##*grace_ms=}"; echo "  ✓ $(t s_http "$detail")" ;;
      "STEP outbox_flushed"*)  echo "  ✓ $(t s_flush)" ;;
      "STEP queues_paused"*)   echo "  ✓ $(t s_paused)" ;;
      "STEP settled"*)         detail="${line#STEP settled }"; echo "  ✓ $(t s_settled "$detail")" ;;
      "STEP backup_start"*)    echo "  … $(t s_bstart)" ;;
      "STEP backup_done"*)     echo "  ✓ $(t s_bdone)" ;;
      "STEP queues_resumed"*)  echo "  ✓ $(t s_resumed)" ;;
      "STEP intake_open"*)     echo "  ✓ $(t s_open)" ;;
      "RESULT "*) ;;  # read from the file afterwards
      *) echo "$line" ;;
    esac
  done
}

fail() {
  local reason="${RESULT#RESULT error }"
  [ "$RESULT" != "${RESULT#RESULT error}" ] || reason="${RESULT:-?}"
  echo "$(t failed "$reason")" >&2
  echo "$(t stays_closed)" >&2
}

# The backup path on the host, from the one inside the container: the volume is
# mounted at /var/lib/sukhi.
host_dir_of() {
  local dir="$1" mount
  case "$dir" in
    /var/lib/sukhi/*)
      mount="$(podman volume inspect "$VOLUME" --format '{{.Mountpoint}}' 2>/dev/null || true)"
      [ -n "$mount" ] && echo "$mount${dir#/var/lib/sukhi}" || true ;;
    *) ;;
  esac
}

run_hook() {
  local dir="$1" host
  [ -n "$HOOK" ] || return 0
  host="$(host_dir_of "$dir")"
  [ -n "$host" ] || echo "$(t no_host_dir)" >&2
  echo "$(t hook_run)"
  SUKHI_BACKUP_DIR="$dir" SUKHI_BACKUP_HOST_DIR="$host" bash -c "$HOOK" || { echo "$(t hook_failed)" >&2; return 3; }
}

backup_dir_of() { echo "$RESULT" | sed -n 's/^RESULT ok backup_dir=//p'; }

# ── The actions ────────────────────────────────────────────────────────────
case "$ACTION" in
  status)
    drain status || { fail; exit 2; }
    echo "${RESULT#RESULT ok }" ;;
  close)
    drain close || { rc=$?; [ "$rc" = 4 ] && exit 4; fail; exit 2; } ;;
  backup)
    drain backup || { rc=$?; [ "$rc" = 4 ] && exit 4; fail; exit 2; }
    dir="$(backup_dir_of)"; echo "$(t backup_at "$dir")"
    run_hook "$dir" || exit 3 ;;
  open)
    drain open || { rc=$?; [ "$rc" = 4 ] && exit 4; echo "$(t failed "${RESULT#RESULT error }")" >&2; exit 2; } ;;
  run)
    drain run || { rc=$?; [ "$rc" = 4 ] && exit 4; fail; exit 2; }
    dir="$(backup_dir_of)"; echo "$(t backup_at "$dir")"
    run_hook "$dir" || exit 3
    if [ "$STOP" = 1 ]; then
      echo "$(t stopping)"
      "${SCTL[@]}" stop "$UNIT"
      echo "$(t stopped)"
    else
      echo "$(t ready)"
    fi ;;
esac
