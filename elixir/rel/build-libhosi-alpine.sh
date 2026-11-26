#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# libhosi for the release images, built from source on the Alpine the release runs on.
#
#   build-libhosi-alpine.sh REF_FILE OUT_DIR
#
# REF_FILE holds the hosigraph commit (the one mix.lock pins for `hosi`); OUT_DIR gets
#   lib/       libhosi.so and every library it needs but musl, each looking for the others
#              next to itself (hosigraph-ex/scripts/bundle-libhosi.sh), so the directory can be
#              copied to the runtime image as it is
#   include/   hosi.h
# `hosi` compiles its NIF against these with HOSI_BUILD=source HOSI_LIB_DIR=OUT_DIR/lib
# HOSI_INCLUDE_DIR=OUT_DIR/include, and finds libhosi at run time through the NIF's rpath, so
# OUT_DIR has to be at the same path in the build and in the runtime image.
#
# hosigraph has no prebuilt release for the commit mix.lock pins (hosi: "... is not in
# checksum.txt"), so a release image builds it, as .github/actions/libhosi does for the tests.
# What it builds is hosigraph's own recipe for the musl bundle (hosigraph-ex/scripts/ci-musl-bundle.sh)
# on the commit that is asked for.
#
# The toolchain is thrown away at the end: only OUT_DIR is meant to be kept.
set -euo pipefail

ref_file=${1:?usage: $0 REF_FILE OUT_DIR}
out=${2:?usage: $0 REF_FILE OUT_DIR}
ref=$(tr -d '[:space:]' < "$ref_file")
[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || { echo "$ref_file does not hold a commit: '$ref'" >&2; exit 1; }

# Keep these in step with .github/actions/libhosi/action.yml.
GHC_VERSION=9.10.3
CABAL_VERSION=3.14.2.0

apk add --no-cache build-base curl git xz perl patchelf \
  gmp-dev libffi-dev ncurses-dev zlib-dev >/dev/null

# ghcup chooses the Alpine (musl, dynamically linked) GHC by itself
export PATH="/root/.ghcup/bin:/root/.cabal/bin:$PATH"
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org |
  BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_MINIMAL=1 BOOTSTRAP_HASKELL_ADJUST_BASHRC=0 sh
ghcup install ghc "$GHC_VERSION" --set
ghcup install cabal "$CABAL_VERSION" --set
ghc --version
cabal --version

src=/hosigraph-src
git init -q "$src"
git -C "$src" fetch -q --depth 1 https://github.com/sukhi-social/hosigraph.git "$ref"
git -C "$src" checkout -q FETCH_HEAD
test "$(git -C "$src" rev-parse HEAD)" = "$ref"

cd "$src"
cabal update
cabal build hosigraph-abi:flib:hosi

lib=$(find dist-newstyle -type f -name 'libhosi.so*' | head -n 1)
test -n "$lib" || { echo "libhosi was not built" >&2; exit 1; }
echo "library: $lib"

mkdir -p "$out/lib" "$out/include"
bash hosigraph-ex/scripts/bundle-libhosi.sh "$lib" "$out/lib"
cp hosigraph-abi/gen/include/hosi.h "$out/include/"

cd /
rm -rf "$src" /root/.ghcup /root/.cabal
ls -l "$out/lib" "$out/include"
