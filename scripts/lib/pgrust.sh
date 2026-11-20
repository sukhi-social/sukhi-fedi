# SPDX-License-Identifier: AGPL-3.0-or-later
#
# pgrust — the PostgreSQL that `make dev` and `make test-pgrust` keep the job
# queues on (pgrust.com: a PostgreSQL 18 compatible server, one binary, no
# Docker). Sourced by scripts/dev.sh, scripts/test-pgrust.sh and
# scripts/pgrust-serve.sh, never run:
#
#   . "$ROOT/scripts/lib/pgrust.sh"
#   pgrust_install                       # sets PGRUST_HOME, fetching it once
#   pgrust_initdb "$DATA"
#   pgrust_start  "$DATA" "$PORT" "$LOG" # sets PGRUST_PID, PGRUST_SOCK
#   pgrust_createdb "$PORT" sukhi_fedi_test
#   ...
#   pgrust_stop
#
# Which release, its checksums, where it is kept and how it is started live
# here and nowhere else.
#
# PGRUST_DIR=/path/to/pgrust   use an installation you already have (it holds
#                              bin/postgres, bin/initdb, bin/psql) instead of
#                              fetching one.
# PGRUST_CACHE=/path           where the fetched release is kept (default:
#                              .pgrust/ in the checkout, which git ignores).

PGRUST_VERSION="0.4-beta"

# The tarball's platform name, or nothing on a machine pgrust has no build for.
pgrust_platform() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo macos-arm64 ;;
    Darwin-x86_64) echo macos-x86_64 ;;
    Linux-x86_64) echo linux-x86_64 ;;
    Linux-aarch64 | Linux-arm64) echo linux-aarch64 ;;
    *) return 1 ;;
  esac
}

# SHA-256 of each tarball, from https://pgrust.com/downloads/v0.4-beta/MANIFEST.txt.
# A new release means new values here, in one go.
pgrust_expected_sha256() {
  case "$1" in
    linux-x86_64) echo 9a53fdc039ca338808702641369b0ac7d6c163124f76f2bfd21860b0be9fb7bb ;;
    linux-aarch64) echo ba5e9358f05c30aaab704e915b88b7890ace629134d9c52b6910311d71a26c94 ;;
    macos-arm64) echo 882bb8db37bd7053821d72d75084b9a98b3383117beb7ddc13cff6725c9431f2 ;;
    macos-x86_64) echo f7751e89525637c196788167cb94a47b80350a993845e2955f22061b795869ab ;;
  esac
}

_pgrust_sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Sets PGRUST_HOME to a directory holding bin/postgres, bin/initdb, bin/psql.
pgrust_install() {
  if [ -n "${PGRUST_DIR:-}" ]; then
    [ -x "$PGRUST_DIR/bin/postgres" ] || {
      echo "→ PGRUST_DIR=$PGRUST_DIR has no bin/postgres" >&2
      return 1
    }
    PGRUST_HOME="$PGRUST_DIR"
    return 0
  fi

  local root platform want home parent tmp got
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  platform="$(pgrust_platform)" || {
    echo "→ pgrust has no build for $(uname -s) $(uname -m); install one yourself and set PGRUST_DIR" >&2
    return 1
  }
  want="$(pgrust_expected_sha256 "$platform")"
  home="${PGRUST_CACHE:-$root/.pgrust}/pgrust-$PGRUST_VERSION-$platform"

  if [ ! -x "$home/bin/postgres" ]; then
    parent="$(dirname "$home")"
    mkdir -p "$parent"
    tmp="$(mktemp -d "$parent/fetch-XXXXXX")"
    echo "→ fetching pgrust $PGRUST_VERSION ($platform, about 30 MB) from pgrust.com"
    # curl, not a browser: macOS marks a browser download as quarantined, and
    # the binaries are signed ad hoc, so they would then refuse to start.
    curl -fsSL -o "$tmp/pgrust.tar.gz" \
      "https://pgrust.com/downloads/v$PGRUST_VERSION/pgrust-$PGRUST_VERSION-$platform.tar.gz" || {
      rm -rf "$tmp"
      echo "→ could not fetch pgrust" >&2
      return 1
    }
    got="$(_pgrust_sha256_of_file "$tmp/pgrust.tar.gz")"
    if [ "$got" != "$want" ]; then
      rm -rf "$tmp"
      echo "→ pgrust checksum mismatch (got $got, want $want); not using it" >&2
      return 1
    fi
    mkdir "$tmp/unpacked"
    tar -xzf "$tmp/pgrust.tar.gz" -C "$tmp/unpacked" --strip-components=1
    rm -rf "$home"
    mv "$tmp/unpacked" "$home"
    rm -rf "$tmp"
  fi
  PGRUST_HOME="$home"
}

# pgrust_initdb DATA_DIR — a fresh cluster whose only user is `postgres`, trusted
# on the local machine (the config's postgres/postgres is then simply accepted).
pgrust_initdb() {
  local out
  out="$("$PGRUST_HOME/bin/initdb" -D "$1" --no-locale --encoding UTF8 -U postgres 2>&1)" || {
    echo "$out" >&2
    return 1
  }
}

# pgrust_start DATA_DIR PORT LOG [extra postgres args] — run the server in the
# background and wait until it accepts connections. Sets PGRUST_PID and
# PGRUST_SOCK (a short-lived directory pgrust_stop removes).
pgrust_start() {
  local data="$1" port="$2" log="$3"
  shift 3
  # A Unix socket path is limited to about 100 bytes, and macOS's $TMPDIR is
  # longer than that, so the socket directory is under /tmp on purpose.
  PGRUST_SOCK="$(mktemp -d /tmp/pgrust-XXXXXX)"
  (
    # pgrust's query engine recurses deeply: it wants a larger stack than the
    # shell's default, and max_stack_depth set to match what it was given.
    ulimit -s 65520 || echo "→ could not raise the stack limit; pgrust may crash on a deep query" >&2
    export RUST_MIN_STACK=33554432
    exec "$PGRUST_HOME/bin/postgres" -D "$data" -k "$PGRUST_SOCK" -p "$port" \
      -c listen_addresses=127.0.0.1 -c io_method=sync -c max_stack_depth=60000 "$@" \
      >"$log" 2>&1
  ) &
  PGRUST_PID=$!
  for _ in $(seq 1 150); do
    nc -z 127.0.0.1 "$port" 2>/dev/null && return 0
    kill -0 "$PGRUST_PID" 2>/dev/null || break
    sleep 0.2
  done
  echo "→ pgrust did not come up on :$port (its log: $log)" >&2
  return 1
}

# pgrust_createdb PORT NAME — create the database unless it is already there.
pgrust_createdb() {
  local port="$1" name="$2" psql here
  psql="$PGRUST_HOME/bin/psql"
  here="$("$psql" -h 127.0.0.1 -p "$port" -U postgres -tAc "select 1 from pg_database where datname = '$name'")" || return 1
  if [ "$here" != 1 ]; then
    "$psql" -h 127.0.0.1 -p "$port" -U postgres -c "create database $name" >/dev/null
  fi
}

# Stop the server pgrust_start began (a fast shutdown, so it does not wait for
# clients) and remove its socket directory. Safe to call twice, or before any start.
pgrust_stop() {
  if [ -n "${PGRUST_PID:-}" ]; then
    kill -INT "$PGRUST_PID" 2>/dev/null || true
    wait "$PGRUST_PID" 2>/dev/null || true
    PGRUST_PID=
  fi
  if [ -n "${PGRUST_SOCK:-}" ]; then
    rm -rf "$PGRUST_SOCK"
    PGRUST_SOCK=
  fi
  return 0
}
